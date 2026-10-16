-- Class auto-cancel db update 12. Every night at 7pm Perth, tomorrow's classes with no bookings are cancelled.
-- Coaches can also cancel a class (booked athletes get a push) or reopen one from REV Admin > Bookings.
-- While bookings are in beta (private.bookings_live() = false) the nightly coach push is held back,
-- because most athletes still book in Gymdesk; the cancellations still show in the app.

create table if not exists public.class_cancellations (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id),
  class_date date not null,
  reason text not null check (reason in ('no_bookings','coach')),
  note text,
  status text not null default 'cancelled' check (status in ('cancelled','reopened')),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  reopened_at timestamptz,
  reopened_by uuid references public.profiles(id),
  unique (class_id, class_date)
);
create index if not exists class_cancellations_date_idx on public.class_cancellations (class_date);
alter table public.class_cancellations enable row level security;
create policy class_cancellations_read on public.class_cancellations for select to authenticated using (private.bookings_visible());
alter publication supabase_realtime add table public.class_cancellations;

-- Nightly job: cancel tomorrow's empty classes.
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
    where c.active and not c.open_session and c.dow = extract(isodow from d)
      and not exists (select 1 from public.class_bookings b where b.class_id = c.id and b.class_date = d and b.status = 'booked')
    on conflict (class_id, class_date) do nothing
    returning class_id
  )
  select count(*), string_agg(to_char(c.start_time, 'FMHH12:MIam') || ' ' || c.name, ', ' order by c.start_time)
    into n, list
  from ins join public.classes c on c.id = ins.class_id;
  if n > 0 and private.bookings_live() then
    select array_agg(id) into coaches from public.profiles where role = 'coach';
    perform private.push_out(coaches, n || ' class' || case when n = 1 then '' else 'es' end || ' cancelled for tomorrow',
      'No bookings by 7pm: ' || list, null, 'admin.html#bookings', 'autocancel', 'classes');
  end if;
  return coalesce(n, 0);
end $$;

-- Coach cancels a class on a date. Anyone booked is cancelled and gets a push.
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
  if n > 0 then
    perform private.push_out(who, 'Class cancelled',
      c.name || ' on ' || to_char(p_date, 'FMDy FMDD FMMon') || ' at ' || to_char(c.start_time, 'FMHH12:MIam') || ' is cancelled.' || coalesce(' ' || nullif(trim(p_note), ''), ''),
      './', null, 'classcancel', null);
  end if;
  return coalesce(n, 0);
end $$;

-- Coach puts a cancelled class back on. Bookings cancelled with it are not restored.
create or replace function public.coach_reopen_class(p_class uuid, p_date date)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  update public.class_cancellations set status = 'reopened', reopened_at = now(), reopened_by = auth.uid()
  where class_id = p_class and class_date = p_date;
end $$;

-- No booking into a cancelled class.
create or replace function private.class_is_cancelled(p_class uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.class_cancellations where class_id = p_class and class_date = p_date and status = 'cancelled');
$$;

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
  select count(*) into n from public.class_bookings where class_id = p_class and class_date = p_date and status = 'booked';
  if c.capacity is not null and n >= c.capacity and not coach then raise exception 'That class is full'; end if;
  insert into public.class_bookings (class_id, class_date, profile_id, booked_by)
    values (p_class, p_date, who, me)
  on conflict (class_id, class_date, profile_id) do update
    set status = 'booked', cancelled_at = null, created_at = now(), booked_by = me
  returning * into r;
  return r;
end $$;

revoke execute on function public.coach_cancel_class(uuid, date, text) from public, anon;
revoke execute on function public.coach_reopen_class(uuid, date) from public, anon;
grant execute on function public.coach_cancel_class(uuid, date, text) to authenticated;
grant execute on function public.coach_reopen_class(uuid, date) to authenticated;

-- 7pm Perth = 11:00 UTC (Perth has no daylight saving)
select cron.schedule('class-autocancel', '0 11 * * *', 'select private.auto_cancel_empty()');

-- db update 13 (16 Oct 2026): per-class switch. PM Barbell Club sessions never auto-cancel; coach push on during beta too (Ant asked).
alter table public.classes add column if not exists auto_cancel boolean not null default true;
update public.classes set auto_cancel = false where program = 'barbell' and start_time >= '12:00';
-- private.auto_cancel_empty() now filters c.auto_cancel and always pushes coaches (no bookings_live() check).
