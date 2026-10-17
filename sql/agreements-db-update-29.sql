-- Agreements db update 29 (17 Oct 2026). Membership agreements, signed in the app.
-- Ant: copy the Gymdesk agreements (Members > Documents), updated: cards not direct debit, inclusions match the app plans,
-- minimum terms kept AND enforced (12 weeks Barbell Club and Platinum, 4 weeks FNDN), holds 14 days' notice for everyone
-- (min 1 week, max 8 weeks a calendar year), no $25 dishonour fee. New joiners sign when joining; existing athletes sign
-- when Ant moves them across (prompt in the app once they have a membership).
-- Texts: agreements/membership-agreements-v1.json (made by agreements/make_agreements.py), loaded with net.http_get.
-- Waiver v2 = Ant's Gymdesk "Waiver and Release Agreement" word for word.

alter table public.membership_plans add column if not exists min_weeks integer check (min_weeks is null or min_weeks between 1 and 104);
alter table public.membership_plans add column if not exists agreement_title text;
alter table public.membership_plans add column if not exists agreement_body text;
alter table public.membership_plans add column if not exists agreement_version integer not null default 1;

create table if not exists public.membership_agreements (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  plan_id uuid not null references public.membership_plans(id),
  membership_id uuid references public.memberships(id) on delete set null,
  version integer not null,
  title text not null,
  body text not null,                 -- exactly what they saw, price filled in
  signed_name text not null,
  signed_at timestamptz not null default now(),
  user_agent text
);
create index if not exists membership_agreements_profile_idx on public.membership_agreements (profile_id, signed_at desc);
alter table public.membership_agreements enable row level security;
create policy membership_agreements_read on public.membership_agreements for select to authenticated using (private.is_coach() or profile_id = auth.uid());

-- The agreement for a plan, price filled in (their own price if they're already on that plan).
create or replace function public.agreement_for(p_plan uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.membership_plans; wk numeric; uid uuid := auth.uid();
begin
  if uid is null then return null; end if;
  select * into p from public.membership_plans where id = p_plan;
  if p.id is null or p.agreement_body is null then return null; end if;
  select coalesce(ms.weekly_price, p.weekly_price) into wk from public.memberships ms
    where ms.profile_id = uid and ms.plan_id = p_plan and (ms.end_date is null or ms.end_date >= (now() at time zone 'Australia/Perth')::date)
    order by ms.start_date desc limit 1;
  wk := coalesce(wk, p.weekly_price);
  return jsonb_build_object('plan_id', p.id, 'plan', p.name, 'version', p.agreement_version, 'title', p.agreement_title,
    'body', replace(p.agreement_body, '{price}', '$' || trim(to_char(wk, 'FM999990.00'))),
    'signed', (select jsonb_build_object('at', a.signed_at, 'name', a.signed_name) from public.membership_agreements a
               where a.profile_id = uid and a.plan_id = p.id and a.version = p.agreement_version order by a.signed_at desc limit 1));
end $$;
revoke execute on function public.agreement_for(uuid) from public, anon;
grant execute on function public.agreement_for(uuid) to authenticated;

-- Sign it. Keeps a copy of exactly what they agreed to. Links to their membership on that plan if they have one.
create or replace function public.sign_agreement(p_plan uuid, p_name text, p_agent text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare a jsonb; uid uuid := auth.uid(); rid uuid; mid uuid;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Type your full name to sign'; end if;
  a := public.agreement_for(p_plan);
  if a is null then raise exception 'There is no agreement for that membership'; end if;
  select id into mid from public.memberships where profile_id = uid and plan_id = p_plan
    and (end_date is null or end_date >= (now() at time zone 'Australia/Perth')::date) order by start_date desc limit 1;
  insert into public.membership_agreements (profile_id, plan_id, membership_id, version, title, body, signed_name, user_agent)
  values (uid, p_plan, mid, (a->>'version')::int, a->>'title', a->>'body', trim(p_name), left(p_agent, 300))
  returning id into rid;
  return rid;
end $$;
revoke execute on function public.sign_agreement(uuid, text, text) from public, anon;
grant execute on function public.sign_agreement(uuid, text, text) to authenticated;

-- My membership now also says whether the agreement is signed and when the minimum term ends.
create or replace function public.my_membership()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); today date := (now() at time zone 'Australia/Perth')::date; cur record; made timestamptz; can boolean;
begin
  if uid is null then return null; end if;
  select ms.id, ms.plan_id, ms.start_date, ms.end_date, ms.billing, ms.amount_paid, p.name, p.description, p.term_weeks, p.min_weeks,
         p.agreement_body is not null as has_agreement, p.agreement_version,
         coalesce(ms.weekly_price, p.weekly_price) as weekly
    into cur
  from public.memberships ms join public.membership_plans p on p.id = ms.plan_id
  where ms.profile_id = uid and (ms.end_date is null or ms.end_date >= today)
  order by ms.start_date limit 1;
  select created_at into made from public.profiles where id = uid;
  can := cur.id is null and (private.is_coach() or made >= timestamptz '2026-10-17 00:00+08');
  return jsonb_build_object(
    'current', case when cur.id is null then null else jsonb_build_object('id', cur.id, 'plan_id', cur.plan_id, 'plan', cur.name, 'description', cur.description,
      'start', cur.start_date, 'end', cur.end_date, 'billing', cur.billing, 'weekly', cur.weekly, 'lump', cur.term_weeks is not null,
      'amount_paid', cur.amount_paid,
      'min_term_end', case when cur.min_weeks is null then null else private.min_term_end(cur.start_date, cur.min_weeks) end,
      'agreement', case when not cur.has_agreement then null else coalesce(
         (select jsonb_build_object('signed', true, 'at', a.signed_at) from public.membership_agreements a
           where a.profile_id = uid and a.plan_id = cur.plan_id and a.version = cur.agreement_version order by a.signed_at desc limit 1),
         jsonb_build_object('signed', false)) end,
      'on_hold', exists (select 1 from public.membership_requests r where r.athlete_id = uid and r.kind = 'hold' and r.status = 'approved'
                          and r.start_date <= today and r.end_date > today)) end,
    'can_join', can,
    'plans', case when can then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'program', program, 'description', description,
                                          'weekly', weekly_price, 'min_weeks', min_weeks) order by sort)
                                          from public.membership_plans where joinable and active), '[]'::jsonb) else '[]'::jsonb end
  );
end $$;

-- Last day of the minimum term: the Sunday at the end of week N, counting the start week as week 1.
create or replace function private.min_term_end(p_start date, p_weeks integer)
returns date language sql immutable as $$
  select (p_start - (extract(isodow from p_start)::int - 1)) + p_weeks * 7 - 1;
$$;

-- Athlete hold and cancel requests now enforce the minimum term and the 8 week a year hold limit.
create or replace function public.request_hold_cancel(p_kind text, p_start date, p_end date, p_reason text)
returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me uuid := auth.uid(); first_ok date := ((now() at time zone 'Australia/Perth')::date + 14); rid uuid; m record; mend date; used int;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if p_kind not in ('hold','cancel') then raise exception 'Choose hold or cancel'; end if;
  if p_start is null then raise exception 'Pick a week'; end if;
  if p_start < first_ok then
    raise exception '14 days notice is required. The earliest date you can pick is %', to_char(first_ok, 'FMDay FMDD FMMonth');
  end if;
  if p_kind = 'hold' then
    if extract(isodow from p_start) <> 1 then raise exception 'Holds start on a Monday (memberships run in full weeks)'; end if;
    if p_end is null or p_end <= p_start or extract(isodow from p_end) <> 1 then raise exception 'Holds are in full weeks, back on a Monday'; end if;
  elsif extract(isodow from p_start) <> 7 then
    raise exception 'Cancellations finish at the end of a week, on a Sunday';
  end if;
  -- minimum term (from their membership in the app, if they have one)
  select ms.start_date, p.min_weeks into m from public.memberships ms join public.membership_plans p on p.id = ms.plan_id
    where ms.profile_id = me and (ms.end_date is null or ms.end_date >= (now() at time zone 'Australia/Perth')::date)
    order by ms.start_date desc limit 1;
  if m.min_weeks is not null then
    mend := private.min_term_end(m.start_date, m.min_weeks);
    if p_kind = 'cancel' and p_start < mend then
      raise exception 'Your % week minimum term runs until %. The earliest last day is then. If there''s a medical reason, message Coach Ant.', m.min_weeks, to_char(mend, 'FMDay FMDD FMMonth');
    end if;
    if p_kind = 'hold' and p_start <= mend then
      raise exception 'Holds can''t start during your % week minimum term (until %). For medical or compassionate reasons, message Coach Ant.', m.min_weeks, to_char(mend, 'FMDay FMDD FMMonth');
    end if;
  end if;
  if p_kind = 'hold' then
    select coalesce(sum((least(end_date, make_date(extract(year from p_start)::int + 1, 1, 1)) - greatest(start_date, make_date(extract(year from p_start)::int, 1, 1))) / 7), 0)::int into used
      from membership_requests where athlete_id = me and kind = 'hold' and status in ('approved','pending')
        and start_date < make_date(extract(year from p_start)::int + 1, 1, 1) and end_date > make_date(extract(year from p_start)::int, 1, 1);
    if used + (p_end - p_start) / 7 > 8 then
      raise exception 'Holds are limited to 8 weeks a calendar year. You have % left for %.', greatest(8 - used, 0), extract(year from p_start)::int;
    end if;
  end if;
  if exists (select 1 from membership_requests where athlete_id = me and status = 'pending') then
    raise exception 'You already have a request waiting for Coach Ant';
  end if;
  insert into membership_requests (athlete_id, kind, start_date, end_date, reason)
  values (me, p_kind, p_start, case when p_kind = 'hold' then p_end end, nullif(trim(coalesce(p_reason,'')), ''))
  returning id into rid;
  return rid;
end; $$;

-- Waiver v2: Ant's Gymdesk Waiver and Release Agreement (loaded from the Gymdesk export), v1 retired.
