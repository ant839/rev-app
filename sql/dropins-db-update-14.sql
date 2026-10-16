-- Drop-ins and free trials db update 14 (REV Admin). Public page trial.html, no account needed:
-- name, email, mobile -> pick a class -> sign the waiver -> booked. Drop-ins count toward class numbers
-- and stop a class being auto-cancelled. When they later create an account, their drop-ins link to it by email.

alter table public.classes add column if not exists trial_ok boolean not null default true;

create table if not exists public.waivers (
  id uuid primary key default gen_random_uuid(),
  version integer not null,
  title text not null default 'Waiver and release',
  body text not null,
  active boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id)
);
create unique index if not exists waivers_one_active on public.waivers (active) where active;
alter table public.waivers enable row level security;
create policy waivers_coach_read on public.waivers for select to authenticated using (private.is_coach());
create policy waivers_coach_insert on public.waivers for insert to authenticated with check (private.is_coach());
create policy waivers_coach_update on public.waivers for update to authenticated using (private.is_coach()) with check (private.is_coach());

create table if not exists public.drop_ins (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'trial' check (kind in ('trial','dropin')),
  full_name text not null,
  email text not null,
  phone text not null,
  class_id uuid not null references public.classes(id),
  class_date date not null,
  status text not null default 'booked' check (status in ('booked','cancelled')),
  waiver_id uuid not null references public.waivers(id),
  waiver_version integer not null,
  signed_name text not null,
  signed_at timestamptz not null default now(),
  user_agent text,
  profile_id uuid references public.profiles(id),
  checked_in_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists drop_ins_once on public.drop_ins (class_id, class_date, lower(email)) where status = 'booked';
create index if not exists drop_ins_date_idx on public.drop_ins (class_date, class_id);
create index if not exists drop_ins_email_idx on public.drop_ins (lower(email));
alter table public.drop_ins enable row level security;
create policy drop_ins_coach_read on public.drop_ins for select to authenticated using (private.is_coach());
create policy drop_ins_coach_update on public.drop_ins for update to authenticated using (private.is_coach()) with check (private.is_coach());
alter publication supabase_realtime add table public.drop_ins;

-- Everything the public page needs: the next 7 days of classes open to trials, spots left, the waiver, the sign-up code.
create or replace function public.trial_setup()
returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (select ((now() at time zone 'Australia/Perth')::date + i) as day from generate_series(0, 6) i),
  slots as (
    select c.id, c.name, c.program, c.start_time, c.end_time, c.capacity, c.coach, d.day,
      (select count(*) from class_bookings b where b.class_id = c.id and b.class_date = d.day and b.status = 'booked')
      + (select count(*) from drop_ins x where x.class_id = c.id and x.class_date = d.day and x.status = 'booked') as taken
    from classes c join d on c.dow = extract(isodow from d.day)
    where c.active and not c.open_session and c.trial_ok
      and not private.class_is_cancelled(c.id, d.day)
      and d.day + c.start_time > (now() at time zone 'Australia/Perth')
  )
  select jsonb_build_object(
    'today', (now() at time zone 'Australia/Perth')::date,
    'classes', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'program', program, 'date', day,
        'start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI'), 'coach', coach,
        'left', case when capacity is null then null else greatest(capacity - taken, 0) end) order by day, start_time) from slots), '[]'::jsonb),
    'waiver', (select jsonb_build_object('id', id, 'version', version, 'title', title, 'body', body) from waivers where active limit 1),
    'join', (select ic.code from invite_codes ic join groups g on g.id = ic.group_id where ic.active and lower(trim(g.name)) = 'free trial' limit 1)
  );
$$;

create or replace function public.trial_book(p_kind text, p_name text, p_email text, p_phone text, p_class uuid, p_date date, p_waiver uuid, p_agent text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.classes; w public.waivers; n integer; r public.drop_ins; coaches uuid[];
  nm text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  em text := lower(btrim(coalesce(p_email, '')));
  ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
  now_perth timestamp := (now() at time zone 'Australia/Perth');
begin
  if p_kind not in ('trial','dropin') then raise exception 'Pick free trial or drop-in'; end if;
  if length(nm) < 2 or length(nm) > 80 then raise exception 'Enter your full name'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(em) > 120 then raise exception 'That email doesn''t look right'; end if;
  if length(regexp_replace(ph, '\D', '', 'g')) not between 8 and 15 then raise exception 'That mobile number doesn''t look right'; end if;
  select * into w from public.waivers where id = p_waiver and active;
  if w.id is null then raise exception 'The waiver has been updated. Refresh the page and try again'; end if;
  select * into c from public.classes where id = p_class;
  if c.id is null or not c.active or c.open_session or not c.trial_ok then raise exception 'That class isn''t available, pick another'; end if;
  if extract(isodow from p_date) <> c.dow then raise exception 'That class doesn''t run on that day'; end if;
  if p_date + c.start_time <= now_perth then raise exception 'That class has already started, pick another'; end if;
  if p_date > now_perth::date + 7 then raise exception 'You can book up to a week ahead'; end if;
  if private.class_is_cancelled(p_class, p_date) then raise exception 'That class is cancelled, pick another'; end if;
  if (select count(*) from public.drop_ins where lower(email) = em and status = 'booked' and class_date >= now_perth::date) >= 3 then
    raise exception 'You already have 3 classes booked. Create an account to book more';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_class::text || p_date::text));
  if exists (select 1 from public.drop_ins where class_id = p_class and class_date = p_date and lower(email) = em and status = 'booked') then
    raise exception 'You''re already booked into that class';
  end if;
  select (select count(*) from public.class_bookings where class_id = p_class and class_date = p_date and status = 'booked')
       + (select count(*) from public.drop_ins where class_id = p_class and class_date = p_date and status = 'booked') into n;
  if c.capacity is not null and n >= c.capacity then raise exception 'That class is full, pick another'; end if;
  insert into public.drop_ins (kind, full_name, email, phone, class_id, class_date, waiver_id, waiver_version, signed_name, user_agent, profile_id)
    values (p_kind, nm, em, ph, p_class, p_date, w.id, w.version, nm, left(p_agent, 300),
            (select id from public.profiles where lower(email) = em limit 1))
  returning * into r;
  select array_agg(id) into coaches from public.profiles where role = 'coach';
  perform private.push_out(coaches, case when p_kind = 'trial' then 'New free trial' else 'New drop-in' end,
    nm || ' booked ' || c.name || ', ' || to_char(p_date, 'FMDy FMDD FMMon') || ' ' || to_char(c.start_time, 'FMHH12:MIam'),
    null, 'admin.html#dropins', 'dropin', 'dropins');
  return jsonb_build_object('id', r.id, 'name', c.name, 'date', p_date, 'start', to_char(c.start_time, 'HH24:MI'), 'end', to_char(c.end_time, 'HH24:MI'));
end $$;

revoke execute on function public.trial_setup() from public;
revoke execute on function public.trial_book(text, text, text, text, uuid, date, uuid, text) from public;
grant execute on function public.trial_setup() to anon, authenticated;
grant execute on function public.trial_book(text, text, text, text, uuid, date, uuid, text) to anon, authenticated;

-- Link drop-ins to the account once they sign up with the same email.
create or replace function private.link_drop_ins() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is not null then
    update public.drop_ins set profile_id = new.id where profile_id is null and lower(email) = lower(new.email);
  end if;
  return new;
end $$;
create trigger profiles_link_drop_ins after insert on public.profiles for each row execute function private.link_drop_ins();

-- Drop-ins count as bookings: class numbers, capacity and the nightly auto-cancel.
create or replace function public.class_counts(p_from date, p_to date)
returns table (class_id uuid, class_date date, booked integer)
language sql stable security definer set search_path = public as $$
  select k.class_id, k.class_date, count(*)::int from (
    select b.class_id, b.class_date from public.class_bookings b where b.status = 'booked' and b.class_date between p_from and p_to
    union all
    select x.class_id, x.class_date from public.drop_ins x where x.status = 'booked' and x.class_date between p_from and p_to
  ) k
  where private.bookings_visible()
  group by k.class_id, k.class_date;
$$;

create or replace function private.auto_cancel_empty()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  d date := (now() at time zone 'Australia/Perth')::date + 1;
  n integer;
  list text;
  coaches uuid[];
begin
  with ins as (
    insert into public.class_cancellations (class_id, class_date, reason)
    select c.id, d, 'no_bookings' from public.classes c
    where c.active and c.auto_cancel and not c.open_session and c.dow = extract(isodow from d)
      and not exists (select 1 from public.class_bookings b where b.class_id = c.id and b.class_date = d and b.status = 'booked')
      and not exists (select 1 from public.drop_ins x where x.class_id = c.id and x.class_date = d and x.status = 'booked')
    on conflict (class_id, class_date) do nothing
    returning class_id
  )
  select count(*), string_agg(to_char(c.start_time, 'FMHH12:MIam') || ' ' || c.name, ', ' order by c.start_time)
    into n, list
  from ins join public.classes c on c.id = ins.class_id;
  if n > 0 then
    select array_agg(id) into coaches from public.profiles where role = 'coach';
    perform private.push_out(coaches, n || ' class' || case when n = 1 then '' else 'es' end || ' cancelled for tomorrow',
      'No bookings by 7pm: ' || list, null, 'admin.html#bookings', 'autocancel', 'classes');
  end if;
  return coalesce(n, 0);
end $$;

-- book_class capacity now includes drop-ins
create or replace function public.book_class(p_class uuid, p_date date, p_profile uuid default null)
returns public.class_bookings
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  coach boolean := private.is_coach();
  who uuid := coalesce(p_profile, auth.uid());
  c public.classes;
  n integer;
  now_perth timestamp := (now() at time zone 'Australia/Perth');
  r public.class_bookings;
begin
  if me is null then raise exception 'Please sign in'; end if;
  if who <> me and not coach then raise exception 'Only coaches can book for someone else'; end if;
  if not private.bookings_visible() then raise exception 'Bookings are not open yet'; end if;
  select * into c from public.classes where id = p_class;
  if c.id is null or not c.active then raise exception 'That class is not on the timetable'; end if;
  if c.open_session then raise exception 'This is an open session. Just sign in when you arrive'; end if;
  if extract(isodow from p_date) <> c.dow then raise exception 'That class does not run on that day'; end if;
  if private.class_is_cancelled(p_class, p_date) then
    raise exception '%', case when coach then 'That class is cancelled. Reopen it first' else 'That class is cancelled' end;
  end if;
  if not coach then
    if p_date + c.start_time <= now_perth then raise exception 'That class has already started'; end if;
    if p_date > now_perth::date + 14 then raise exception 'Bookings open 14 days ahead'; end if;
    if not exists (select 1 from public.group_members where profile_id = who and group_id = any(c.group_ids)) then
      raise exception 'Your membership does not include this class';
    end if;
  end if;
  perform pg_advisory_xact_lock(hashtext(p_class::text || p_date::text));
  if exists (select 1 from public.class_bookings where class_id = p_class and class_date = p_date and profile_id = who and status = 'booked') then
    raise exception 'Already booked in';
  end if;
  select (select count(*) from public.class_bookings where class_id = p_class and class_date = p_date and status = 'booked')
       + (select count(*) from public.drop_ins where class_id = p_class and class_date = p_date and status = 'booked') into n;
  if c.capacity is not null and n >= c.capacity and not coach then raise exception 'That class is full'; end if;
  insert into public.class_bookings (class_id, class_date, profile_id, booked_by)
    values (p_class, p_date, who, me)
  on conflict (class_id, class_date, profile_id) do update
    set status = 'booked', cancelled_at = null, created_at = now(), booked_by = me
  returning * into r;
  return r;
end $$;

-- Coach cancelling a class also cancels its drop-ins (coach rings them; they have no app).
create or replace function public.coach_cancel_class(p_class uuid, p_date date, p_note text default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare c public.classes; who uuid[]; n integer;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  select * into c from public.classes where id = p_class;
  if c.id is null then raise exception 'Class not found'; end if;
  insert into public.class_cancellations (class_id, class_date, reason, note, created_by)
    values (p_class, p_date, 'coach', nullif(trim(p_note), ''), auth.uid())
  on conflict (class_id, class_date) do update
    set status = 'cancelled', reason = 'coach', note = excluded.note, created_by = auth.uid(), created_at = now(), reopened_at = null, reopened_by = null;
  with x as (
    update public.class_bookings set status = 'cancelled', cancelled_at = now()
    where class_id = p_class and class_date = p_date and status = 'booked'
    returning profile_id
  ) select array_agg(profile_id), count(*) into who, n from x;
  update public.drop_ins set status = 'cancelled', cancelled_at = now() where class_id = p_class and class_date = p_date and status = 'booked';
  if n > 0 then
    perform private.push_out(who, 'Class cancelled',
      c.name || ' on ' || to_char(p_date, 'FMDy FMDD FMMon') || ' at ' || to_char(c.start_time, 'FMHH12:MIam') || ' is cancelled.' || coalesce(' ' || nullif(trim(p_note), ''), ''),
      './', null, 'classcancel', null);
  end if;
  return coalesce(n, 0);
end $$;

-- db update 15 (16 Oct 2026): Ant wants people to pick what they're trying (FNDN = Strength and Conditioning,
-- Barbell Club = Olympic Weightlifting). FNDN Oly is not open for trials.
update public.classes set trial_ok = false where name = 'FNDN Oly';
alter table public.drop_ins add column if not exists program text check (program in ('fndn','barbell'));
-- public.trial_book(..., p_agent text, p_program text): checks the class belongs to the picked program,
-- calls the 8-argument trial_book, then stores drop_ins.program. trial.html always passes p_program.
