-- Sign-in db update 18: front desk tablet (kiosk.html). Athletes type their name or 4-digit code,
-- then tap what they're here for (today's class, Open Gym, PT). Signed in = checked_in_at on the booking.
-- The tablet is signed in as a coach or as a front desk account listed in public.kiosk_accounts.

create table if not exists public.checkin_codes (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  code text not null unique check (code ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now()
);
alter table public.checkin_codes enable row level security;
create policy checkin_codes_own on public.checkin_codes for select to authenticated using (profile_id = auth.uid() or private.is_coach());
create policy checkin_codes_coach_update on public.checkin_codes for update to authenticated using (private.is_coach()) with check (private.is_coach());

create table if not exists public.kiosk_accounts (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  label text not null default 'Front desk',
  created_at timestamptz not null default now()
);
alter table public.kiosk_accounts enable row level security;
create policy kiosk_accounts_coach_read on public.kiosk_accounts for select to authenticated using (private.is_coach() or profile_id = auth.uid());
create policy kiosk_accounts_coach_insert on public.kiosk_accounts for insert to authenticated with check (private.is_coach());

create or replace function private.is_kiosk() returns boolean
language sql stable security definer set search_path = public as $$
  select private.is_coach() or exists (select 1 from public.kiosk_accounts where profile_id = auth.uid());
$$;
grant execute on function private.is_kiosk() to authenticated;

-- Give every profile a unique 4-digit code (new sign-ups too).
create or replace function private.new_checkin_code() returns text
language plpgsql volatile set search_path = public as $$
declare c text; i int := 0;
begin
  loop
    c := lpad((floor(random() * 9000) + 1000)::int::text, 4, '0');
    exit when not exists (select 1 from public.checkin_codes where code = c);
    i := i + 1; if i > 200 then raise exception 'No free sign-in codes left'; end if;
  end loop;
  return c;
end $$;

create or replace function private.give_checkin_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.checkin_codes (profile_id, code) values (new.id, private.new_checkin_code()) on conflict do nothing;
  return new;
end $$;
create trigger profiles_give_checkin_code after insert on public.profiles for each row execute function private.give_checkin_code();

do $$ declare r record; begin
  for r in select p.id from public.profiles p where not exists (select 1 from public.checkin_codes c where c.profile_id = p.id) loop
    insert into public.checkin_codes (profile_id, code) values (r.id, private.new_checkin_code());
  end loop;
end $$;

-- Coach: give someone a fresh code.
create or replace function public.coach_new_checkin_code(p_profile uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c text := private.new_checkin_code();
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  insert into public.checkin_codes (profile_id, code) values (p_profile, c)
  on conflict (profile_id) do update set code = excluded.code, created_at = now();
  return c;
end $$;

-- Kiosk screen 1: find by code (exact) or name (any word starts with what was typed). Athletes and today's drop-ins.
create or replace function public.kiosk_find(p_q text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := lower(btrim(coalesce(p_q, ''))); today date := (now() at time zone 'Australia/Perth')::date; res jsonb;
begin
  if not private.is_kiosk() then raise exception 'This screen needs the front desk login'; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into res from (
    select jsonb_build_object('type', 'athlete', 'id', p.id, 'name', coalesce(p.full_name, p.email)) x
    from public.profiles p left join public.checkin_codes cc on cc.profile_id = p.id
    where coalesce(p.active, true) and not exists (select 1 from public.kiosk_accounts k where k.profile_id = p.id)
      and (cc.code = q or (q !~ '^[0-9]+$' and exists (
        select 1 from regexp_split_to_table(lower(coalesce(p.full_name, '')), '\s+') w where w like q || '%')
        or (q !~ '^[0-9]+$' and lower(coalesce(p.full_name, '')) like q || '%')))
    union all
    select jsonb_build_object('type', 'dropin', 'id', d.id, 'name', d.full_name)
    from public.drop_ins d
    where d.class_date = today and d.status = 'booked' and d.profile_id is null and q !~ '^[0-9]+$'
      and exists (select 1 from regexp_split_to_table(lower(d.full_name), '\s+') w where w like q || '%')
    limit 8
  ) s;
  return res;
end $$;

-- Kiosk screen 2: today's choices. Classes from 60 minutes before start until they finish, plus open sessions.
create or replace function public.kiosk_options(p_profile uuid default null, p_dropin uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Australia/Perth')::date;
  nowt time := (now() at time zone 'Australia/Perth')::time;
  nm text; d public.drop_ins; res jsonb;
begin
  if not private.is_kiosk() then raise exception 'This screen needs the front desk login'; end if;
  if p_dropin is not null then
    select * into d from public.drop_ins where id = p_dropin;
    if d.id is null then raise exception 'Booking not found'; end if;
    select jsonb_build_object('name', d.full_name, 'options', coalesce(jsonb_agg(jsonb_build_object(
      'class_id', c.id, 'name', c.name, 'start', to_char(c.start_time, 'HH24:MI'), 'end', to_char(c.end_time, 'HH24:MI'),
      'open', false, 'booked', true, 'in', d.checked_in_at is not null, 'dropin', true)), '[]'::jsonb))
    into res from public.classes c where c.id = d.class_id;
    return res;
  end if;
  select coalesce(full_name, email) into nm from public.profiles where id = p_profile;
  if nm is null then raise exception 'Athlete not found'; end if;
  with g as (select group_id from public.group_members where profile_id = p_profile),
  opts as (
    select c.id, c.name, c.start_time, c.end_time, c.open_session, c.sort,
      b.status = 'booked' as booked, b.checked_in_at is not null as is_in
    from public.classes c
    left join public.class_bookings b on b.class_id = c.id and b.class_date = today and b.profile_id = p_profile
    where c.active and (c.group_ids && array(select group_id from g) or b.status = 'booked')
      and (c.open_session or (c.dow = extract(isodow from today) and nowt between c.start_time - interval '60 minutes' and c.end_time
                              and not private.class_is_cancelled(c.id, today)))
  )
  select jsonb_build_object('name', nm, 'options', coalesce(jsonb_agg(jsonb_build_object(
    'class_id', id, 'name', name, 'start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI'),
    'open', open_session, 'booked', coalesce(booked, false), 'in', coalesce(is_in, false))
    order by open_session, coalesce(booked, false) desc, start_time, sort), '[]'::jsonb))
  into res from opts;
  return res;
end $$;

-- Sign in. Athletes: books them in if they weren't (walk-ins are fine) and stamps checked_in_at. Drop-ins: stamps their booking.
create or replace function public.kiosk_checkin(p_class uuid, p_profile uuid default null, p_dropin uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Australia/Perth')::date; c public.classes; nm text;
begin
  if not private.is_kiosk() then raise exception 'This screen needs the front desk login'; end if;
  select * into c from public.classes where id = p_class and active;
  if c.id is null then raise exception 'That class is not on today'; end if;
  if p_dropin is not null then
    update public.drop_ins set checked_in_at = coalesce(checked_in_at, now()) where id = p_dropin and class_id = p_class and class_date = today returning full_name into nm;
    if nm is null then raise exception 'Booking not found for today'; end if;
  else
    if not c.open_session and c.dow <> extract(isodow from today) then raise exception 'That class is not on today'; end if;
    insert into public.class_bookings (class_id, class_date, profile_id, booked_by, checked_in_at)
      values (p_class, today, p_profile, auth.uid(), now())
    on conflict (class_id, class_date, profile_id) do update
      set status = 'booked', cancelled_at = null, checked_in_at = coalesce(public.class_bookings.checked_in_at, now());
    select coalesce(full_name, email) into nm from public.profiles where id = p_profile;
  end if;
  return jsonb_build_object('name', nm, 'class', c.name);
end $$;

revoke execute on function public.kiosk_find(text) from public, anon;
revoke execute on function public.kiosk_options(uuid, uuid) from public, anon;
revoke execute on function public.kiosk_checkin(uuid, uuid, uuid) from public, anon;
revoke execute on function public.coach_new_checkin_code(uuid) from public, anon;
grant execute on function public.kiosk_find(text) to authenticated;
grant execute on function public.kiosk_options(uuid, uuid) to authenticated;
grant execute on function public.kiosk_checkin(uuid, uuid, uuid) to authenticated;
grant execute on function public.coach_new_checkin_code(uuid) to authenticated;

-- db update 19 (16 Oct 2026): kiosk_options: coaches see every option; Open Gym (Whole Team) is open to everyone;
-- classes show for the rest of the day (soon = from 60 min before start) so the tablet splits On now / Later today.

-- db update 20 (16 Oct 2026): kiosk_find returns 'avatar' (profiles.avatar_path) so the tablet shows profile photos.
