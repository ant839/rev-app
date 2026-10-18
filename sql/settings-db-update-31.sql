-- Settings db update 31 (18 Oct 2026). Ant: "an easy toggle on / toggle off" for athletes seeing class numbers, and start a
-- settings page. public.app_settings holds switches coaches flip in REV Admin > Settings (secrets stay in private.app_config).
--   show_spots_left   athletes (and the trial page) see "X of Y spots left". Off: athletes only see Full.
--   bookings_live     in-app booking for everyone, not just Beta Testers (ends the bookings beta).
--   agreements_live   membership agreements, Join here! and the minimum term / fee / cooling-off rules for athletes.
--                     Turning it on also switches the waiver to Ant's Gymdesk Waiver and Release Agreement (v2).

create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);
alter table public.app_settings enable row level security;
create policy app_settings_read on public.app_settings for select to authenticated using (true);
create policy app_settings_coach_update on public.app_settings for update to authenticated using (private.is_coach()) with check (private.is_coach());
grant select, update on public.app_settings to authenticated;

insert into public.app_settings (key, value) values
  ('show_spots_left', 'false'), ('bookings_live', 'false'),
  ('agreements_live', to_jsonb(coalesce((select value from private.app_config where key = 'agreements_live'), 'false') = 'true'))
on conflict (key) do nothing;

create or replace function private.setting_on(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true'::jsonb from public.app_settings where key = p_key), false);
$$;
create or replace function private.bookings_live() returns boolean language sql stable security definer set search_path = public as $$
  select private.setting_on('bookings_live');
$$;
create or replace function private.agreements_live() returns boolean language sql stable security definer set search_path = public as $$
  select private.setting_on('agreements_live');
$$;

-- who changed it and when; agreements going live switches the waiver to the Gymdesk one
create or replace function private.settings_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now(); new.updated_by := auth.uid();
  if new.key = 'agreements_live' and new.value = 'true'::jsonb and old.value is distinct from new.value
     and exists (select 1 from public.waivers where version = 2 and not active) then
    update public.waivers set active = false where active;
    update public.waivers set active = true where version = 2;
  end if;
  return new;
end $$;
create trigger app_settings_touch before update on public.app_settings for each row execute function private.settings_touch();

-- class numbers: coaches and the front desk always; athletes only when show_spots_left is on (otherwise just full classes)
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
  ), full_view as (select private.is_coach() or private.is_kiosk() or private.setting_on('show_spots_left') as v)
  select k.class_id, k.class_date, case when (select v from full_view) then k.n else c.capacity end
  from k join public.classes c on c.id = k.class_id
  where (select v from full_view) or (c.capacity is not null and k.n >= c.capacity);
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
        'left', case when capacity is null then null
                     when private.setting_on('show_spots_left') then greatest(capacity - taken, 0)
                     when taken >= capacity then 0 else null end) order by day, start_time) from slots), '[]'::jsonb),
    'waiver', (select jsonb_build_object('id', id, 'version', version, 'title', title, 'body', body) from waivers where active limit 1),
    'join', (select ic.code from invite_codes ic join groups g on g.id = ic.group_id where ic.active and lower(trim(g.name)) = 'free trial' limit 1)
  );
$$;

-- 31b (applied): public.app_settings already existed (the coach app keeps its own rows there: imp_*, periodisation,
-- records_sync, class_only, due_overrides). Added updated_by; the trigger only stamps the three REV Admin switches.
alter table public.app_settings add column if not exists updated_by uuid references public.profiles(id);
