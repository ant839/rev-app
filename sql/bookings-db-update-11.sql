-- Bookings db update 11: class timetable and bookings (REV Admin, phase 1). Beta only.
-- Visible to coaches and the Beta Testers group until private.bookings_live() returns true.

-- Going live later = change this function to `select true`.
create or replace function private.bookings_live() returns boolean
language sql stable as $$ select false $$;

create or replace function private.bookings_visible() returns boolean
language sql stable security definer set search_path = public as $$
  select private.bookings_live() or private.is_coach() or exists (
    select 1 from public.group_members gm join public.groups g on g.id = gm.group_id
    where gm.profile_id = auth.uid() and lower(trim(g.name)) = 'beta testers');
$$;
grant execute on function private.bookings_live() to authenticated;
grant execute on function private.bookings_visible() to authenticated;

-- Weekly timetable. Open sessions (Open Gym, PT) have no day or time: athletes just sign in to them.
create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  program text not null default 'fndn' check (program in ('fndn','barbell','open')),
  dow smallint check (dow between 1 and 7),          -- 1 = Monday ... 7 = Sunday
  start_time time,
  end_time time,
  capacity integer check (capacity is null or capacity > 0),
  coach text,
  group_ids uuid[] not null default '{}',            -- groups whose athletes can book it
  open_session boolean not null default false,
  active boolean not null default true,
  sort integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (open_session or (dow is not null and start_time is not null and end_time is not null and end_time > start_time))
);

create table if not exists public.class_bookings (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id),
  class_date date not null,
  profile_id uuid not null references public.profiles(id),
  status text not null default 'booked' check (status in ('booked','cancelled')),
  booked_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  checked_in_at timestamptz,
  unique (class_id, class_date, profile_id)
);
create index if not exists class_bookings_date_idx on public.class_bookings (class_date, class_id);
create index if not exists class_bookings_profile_idx on public.class_bookings (profile_id, class_date);

alter table public.classes enable row level security;
alter table public.class_bookings enable row level security;

create policy classes_read on public.classes for select to authenticated using (private.bookings_visible());
create policy classes_coach_insert on public.classes for insert to authenticated with check (private.is_coach());
create policy classes_coach_update on public.classes for update to authenticated using (private.is_coach()) with check (private.is_coach());

create policy bookings_read on public.class_bookings for select to authenticated
  using (private.is_coach() or (profile_id = auth.uid() and private.bookings_visible()));
create policy bookings_coach_update on public.class_bookings for update to authenticated using (private.is_coach()) with check (private.is_coach());
-- Inserts and athlete cancellations go through the RPCs below.

-- Book a class on a date. Coaches can book for someone else and override the group rule.
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

-- Cancel a booking: the athlete before the class starts, or a coach any time.
create or replace function public.cancel_booking(p_booking uuid)
returns public.class_bookings
language plpgsql security definer set search_path = public as $$
declare
  b public.class_bookings;
  c public.classes;
  coach boolean := private.is_coach();
begin
  select * into b from public.class_bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found'; end if;
  if b.profile_id <> auth.uid() and not coach then raise exception 'Not your booking'; end if;
  if not private.bookings_visible() then raise exception 'Bookings are not open yet'; end if;
  select * into c from public.classes where id = b.class_id;
  if not coach and b.class_date + c.start_time <= (now() at time zone 'Australia/Perth') then
    raise exception 'That class has already started';
  end if;
  update public.class_bookings set status = 'cancelled', cancelled_at = now() where id = p_booking returning * into b;
  return b;
end $$;

-- How many are booked into each class over a date range (athletes only see counts, not names).
create or replace function public.class_counts(p_from date, p_to date)
returns table (class_id uuid, class_date date, booked integer)
language sql stable security definer set search_path = public as $$
  select b.class_id, b.class_date, count(*)::int
  from public.class_bookings b
  where private.bookings_visible() and b.status = 'booked' and b.class_date between p_from and p_to
  group by b.class_id, b.class_date;
$$;

revoke execute on function public.book_class(uuid, date, uuid) from public, anon;
revoke execute on function public.cancel_booking(uuid) from public, anon;
revoke execute on function public.class_counts(date, date) from public, anon;
grant execute on function public.book_class(uuid, date, uuid) to authenticated;
grant execute on function public.cancel_booking(uuid) to authenticated;
grant execute on function public.class_counts(date, date) to authenticated;

alter publication supabase_realtime add table public.class_bookings;
