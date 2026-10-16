-- Memberships db update 23 (16 Oct 2026). Ant: 3 Day can only book in and attend 3 times a week;
-- PT Only (free, sign in for PT only); PT Client (free, pays Ant directly, can use Barbell Club and Open Gym).
-- Plans now carry their access: saving someone's membership adds them to the plan's groups (never removes any).

alter table public.membership_plans add column if not exists weekly_limit integer check (weekly_limit is null or weekly_limit > 0);
alter table public.membership_plans add column if not exists group_ids uuid[] not null default '{}';

insert into public.groups (name, description, sort)
select 'PT Only', 'Only come in for PT sessions. Sign in to PT, no classes or open gym.', (select coalesce(max(sort), 0) + 1 from public.groups)
where not exists (select 1 from public.groups where name = 'PT Only');

insert into public.membership_plans (name, program, weekly_price, description, sort)
select v.* from (values
  ('PT Client', 'pt', 0.00, 'Pays Ant directly for PT. Free membership: PT, Barbell Club and open gym.', 50),
  ('PT Only', 'pt', 0.00, 'Only comes in with a PT. Free membership: signs in to PT sessions only.', 60)
) v(name, program, weekly_price, description, sort)
where not exists (select 1 from public.membership_plans p where p.name = v.name);

update public.membership_plans set weekly_limit = 3 where name = 'Barbell Club 3 Day';
update public.membership_plans p set group_ids = array(select g.id from public.groups g where g.name = any(
  case p.name
    when 'Barbell Club 3 Day' then array['Barbell Club']
    when 'Barbell Club Gold'  then array['Barbell Club']
    when 'FNDN Gold'          then array['FNDN']
    when 'Platinum'           then array['Barbell Club', 'FNDN']
    when 'PT Client'          then array['PT Clients']
    when 'PT Only'            then array['PT Only']
    else array[]::text[] end));

-- PT Clients can book Barbell Club sessions; PT Only can sign in to PT.
update public.classes c set group_ids = array(select distinct unnest(c.group_ids || array[(select id from public.groups where name = 'PT Clients')]))
where c.program = 'barbell';
update public.classes c set group_ids = array(select distinct unnest(c.group_ids || array[(select id from public.groups where name = 'PT Only')]))
where c.name = 'Personal Training' and c.open_session;

-- Saving a membership adds the athlete to the plan's groups.
create or replace function private.membership_groups() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.group_members (group_id, profile_id)
  select unnest(p.group_ids), new.profile_id from public.membership_plans p where p.id = new.plan_id
  on conflict do nothing;
  return new;
end $$;
create trigger memberships_add_groups after insert or update of plan_id on public.memberships
  for each row execute function private.membership_groups();

-- Weekly session limit (3 Day). Counts class bookings Monday to Sunday, not open sessions.
create or replace function private.week_limit_left(p_profile uuid, p_date date, p_class uuid default null)
returns integer
language sql stable security definer set search_path = public as $$
  with m as (
    select p.weekly_limit from public.memberships ms join public.membership_plans p on p.id = ms.plan_id
    where ms.profile_id = p_profile and ms.start_date <= p_date and (ms.end_date is null or ms.end_date >= p_date)
    order by ms.start_date desc limit 1
  )
  select case when (select weekly_limit from m) is null then null else
    (select weekly_limit from m) - (
      select count(*)::int from public.class_bookings b join public.classes c on c.id = b.class_id
      where b.profile_id = p_profile and b.status = 'booked' and not c.open_session
        and b.class_date between (p_date - (extract(isodow from p_date)::int - 1)) and (p_date + (7 - extract(isodow from p_date)::int))
        and not (b.class_id is not distinct from p_class and b.class_date = p_date))
  end;
$$;

-- book_class: 3 Day athletes stop at 3 a week (coaches can still book them in).
create or replace function public.book_class(p_class uuid, p_date date, p_profile uuid default null)
returns public.class_bookings
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  coach boolean := private.is_coach();
  who uuid := coalesce(p_profile, auth.uid());
  c public.classes;
  n integer; lft integer;
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
    lft := private.week_limit_left(who, p_date, p_class);
    if lft is not null and lft <= 0 then
      raise exception 'Your membership covers 3 sessions a week and you''ve booked them all for that week. Cancel one to book this, or ask a coach';
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

-- Tablet: 3 Day athletes who've used their 3 can't sign in to another class (open gym and PT are fine).
create or replace function public.kiosk_checkin(p_class uuid, p_profile uuid default null, p_dropin uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Australia/Perth')::date; c public.classes; nm text; lft integer;
begin
  if not private.is_kiosk() then raise exception 'This screen needs the front desk login'; end if;
  select * into c from public.classes where id = p_class and active;
  if c.id is null then raise exception 'That class is not on today'; end if;
  if p_dropin is not null then
    update public.drop_ins set checked_in_at = coalesce(checked_in_at, now()) where id = p_dropin and class_id = p_class and class_date = today returning full_name into nm;
    if nm is null then raise exception 'Booking not found for today'; end if;
  else
    if not c.open_session and c.dow <> extract(isodow from today) then raise exception 'That class is not on today'; end if;
    if not c.open_session and not exists (select 1 from public.class_bookings where class_id = p_class and class_date = today and profile_id = p_profile and status = 'booked') then
      lft := private.week_limit_left(p_profile, today, p_class);
      if lft is not null and lft <= 0 then raise exception 'You''ve used your 3 sessions this week. See a coach'; end if;
    end if;
    insert into public.class_bookings (class_id, class_date, profile_id, booked_by, checked_in_at)
      values (p_class, today, p_profile, auth.uid(), now())
    on conflict (class_id, class_date, profile_id) do update
      set status = 'booked', cancelled_at = null, checked_in_at = coalesce(public.class_bookings.checked_in_at, now());
    select coalesce(full_name, email) into nm from public.profiles where id = p_profile;
  end if;
  return jsonb_build_object('name', nm, 'class', c.name);
end $$;

-- Tablet choices: PT Only athletes don't get Open Gym. Adds weekly sessions left for 3 Day athletes.
create or replace function public.kiosk_options(p_profile uuid default null, p_dropin uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Australia/Perth')::date;
  nowt time := (now() at time zone 'Australia/Perth')::time;
  nm text; d public.drop_ins; res jsonb; is_coach_p boolean; pt_only boolean;
begin
  if not private.is_kiosk() then raise exception 'This screen needs the front desk login'; end if;
  if p_dropin is not null then
    select * into d from public.drop_ins where id = p_dropin;
    if d.id is null then raise exception 'Booking not found'; end if;
    select jsonb_build_object('name', d.full_name, 'options', coalesce(jsonb_agg(jsonb_build_object(
      'class_id', c.id, 'name', c.name, 'start', to_char(c.start_time, 'HH24:MI'), 'end', to_char(c.end_time, 'HH24:MI'),
      'open', false, 'booked', true, 'in', d.checked_in_at is not null, 'dropin', true, 'soon', true)), '[]'::jsonb))
    into res from public.classes c where c.id = d.class_id;
    return res;
  end if;
  select coalesce(full_name, email), role = 'coach' into nm, is_coach_p from public.profiles where id = p_profile;
  if nm is null then raise exception 'Athlete not found'; end if;
  pt_only := exists (select 1 from public.group_members gm join public.groups g on g.id = gm.group_id where gm.profile_id = p_profile and g.name = 'PT Only')
             and not exists (select 1 from public.group_members gm join public.groups g on g.id = gm.group_id where gm.profile_id = p_profile and g.name in ('Barbell Club','FNDN','PT Clients'));
  with g as (select group_id from public.group_members where profile_id = p_profile),
  opts as (
    select c.id, c.name, c.start_time, c.end_time, c.open_session, c.sort,
      b.status = 'booked' as booked, b.checked_in_at is not null as is_in
    from public.classes c
    left join public.class_bookings b on b.class_id = c.id and b.class_date = today and b.profile_id = p_profile
    where c.active
      and (is_coach_p
           or c.group_ids && array(select group_id from g)
           or b.status = 'booked'
           or (c.open_session and not pt_only and exists (select 1 from public.groups wt where wt.id = any(c.group_ids) and wt.name = 'Whole Team')))
      and (c.open_session or (c.dow = extract(isodow from today) and nowt <= c.end_time and not private.class_is_cancelled(c.id, today)))
  )
  select jsonb_build_object('name', nm, 'left', private.week_limit_left(p_profile, today), 'options', coalesce(jsonb_agg(jsonb_build_object(
    'class_id', id, 'name', name, 'start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI'),
    'open', open_session, 'booked', coalesce(booked, false), 'in', coalesce(is_in, false),
    'soon', open_session or nowt >= start_time - interval '60 minutes')
    order by open_session, coalesce(booked, false) desc, start_time, sort), '[]'::jsonb))
  into res from opts;
  return res;
end $$;

-- Athlete app: how many sessions they have left in a week (null = no limit).
create or replace function public.my_week_left(p_date date)
returns integer
language sql stable security definer set search_path = public as $$
  select private.week_limit_left(auth.uid(), p_date);
$$;
revoke execute on function public.my_week_left(date) from public, anon;
grant execute on function public.my_week_left(date) to authenticated;

-- 6 Month Ultimate (Ant): all classes, paid as a discounted lump sum, amount set per athlete.
alter table public.membership_plans add column if not exists term_weeks integer check (term_weeks is null or term_weeks > 0);
alter table public.memberships add column if not exists amount_paid numeric(8,2) check (amount_paid is null or amount_paid >= 0);
insert into public.membership_plans (name, program, weekly_price, description, term_weeks, sort)
select '6 Month Ultimate', 'other', 0.00, 'All classes, Barbell Club and FNDN. Paid up front as a lump sum; amount set per athlete.', 26, 45
where not exists (select 1 from public.membership_plans where name = '6 Month Ultimate');
update public.membership_plans set group_ids = array(select id from public.groups where name in ('Barbell Club','FNDN'))
where name = '6 Month Ultimate';
-- (Applied as one migration with the 6 Month Ultimate plan included in the plan insert.)
