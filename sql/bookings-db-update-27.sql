-- Bookings db update 27 (17 Oct 2026). Ant: athletes must not see how many people are booked in.
-- class_counts: coaches and the front desk tablet still get real numbers. Everyone else only learns which classes are FULL
-- (booked = capacity on full classes, no row otherwise). trial_setup: 'left' is 0 when full, otherwise null ("Spots available").
create or replace function public.class_counts(p_from date, p_to date)
returns table (class_id uuid, class_date date, booked integer)
language sql stable security definer set search_path = public as $$
  with k as (
    select k.class_id, k.class_date, count(*)::int as n from (
      select b.class_id, b.class_date from public.class_bookings b where b.status = 'booked' and b.class_date between p_from and p_to
      union all
      select x.class_id, x.class_date from public.drop_ins x where x.status = 'booked' and x.class_date between p_from and p_to
    ) k
    where private.bookings_visible()
    group by k.class_id, k.class_date
  )
  select k.class_id, k.class_date, case when private.is_coach() or private.is_kiosk() then k.n else c.capacity end
  from k join public.classes c on c.id = k.class_id
  where private.is_coach() or private.is_kiosk() or (c.capacity is not null and k.n >= c.capacity);
$$;

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
        'left', case when capacity is not null and taken >= capacity then 0 else null end) order by day, start_time) from slots), '[]'::jsonb),
    'waiver', (select jsonb_build_object('id', id, 'version', version, 'title', title, 'body', body) from waivers where active limit 1),
    'join', (select ic.code from invite_codes ic join groups g on g.id = ic.group_id where ic.active and lower(trim(g.name)) = 'free trial' limit 1)
  );
$$;
