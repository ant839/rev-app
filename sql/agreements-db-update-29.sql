-- Agreements db update 29 (17 Oct 2026). Membership agreements, signed in the app.
-- Ant: copy the Gymdesk agreements (Members > Documents), updated: cards not direct debit, inclusions match the app plans,
-- minimum terms kept AND enforced (12 weeks Barbell Club and Platinum, 4 weeks FNDN), holds 14 days' notice for everyone
-- (min 1 week, max 8 weeks a calendar year), no $25 dishonour fee. New joiners sign when joining; existing athletes sign
-- when Ant moves them across (prompt in the app once they have a membership).
-- Ant (17 Oct, later): whole weeks Mon to Sun, no partial weeks; 12 week plans (Barbell Club, Platinum) can cancel inside the
-- minimum term with 30 days' notice and a $200 early cancellation fee (charged when approved, if billed through the app).
-- FNDN (4 weeks): inside the term only for medical or relocation reasons (Ant approves). WA Fitness Industry Code: 7 day
-- cooling-off (cancel straight away, no notice), athletes reminded before their minimum term ends.
-- Texts: agreements/membership-agreements-v1.json (made by agreements/make_agreements.py), loaded with net.http_get.
-- Waiver v2 = Ant's Gymdesk "Waiver and Release Agreement" word for word.

alter table public.membership_plans add column if not exists min_weeks integer check (min_weeks is null or min_weeks between 1 and 104);
alter table public.membership_plans add column if not exists agreement_title text;
alter table public.membership_plans add column if not exists agreement_body text;
alter table public.membership_plans add column if not exists agreement_version integer not null default 1;
alter table public.membership_plans add column if not exists early_cancel_fee numeric(8,2);      -- inside the minimum term (with 30 days' notice)
alter table public.membership_requests add column if not exists fee_cents integer;               -- early cancellation fee for this request
alter table public.membership_requests add column if not exists fee_charge_id uuid;
alter table public.memberships add column if not exists min_term_notified_at timestamptz;

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

-- Last day of the minimum term: the Sunday at the end of week N, counting the start week as week 1.
create or replace function private.min_term_end(p_start date, p_weeks integer)
returns date language sql immutable as $$
  select (p_start - (extract(isodow from p_start)::int - 1)) + p_weeks * 7 - 1;
$$;

-- The agreement for a plan, price filled in (their own price if they're already on that plan).
create or replace function public.agreement_for(p_plan uuid, p_start date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.membership_plans; wk numeric; st date; uid uuid := auth.uid(); b text;
begin
  if uid is null then return null; end if;
  select * into p from public.membership_plans where id = p_plan;
  if p.id is null or p.agreement_body is null then return null; end if;
  select coalesce(ms.weekly_price, p.weekly_price), ms.start_date into wk, st from public.memberships ms
    where ms.profile_id = uid and ms.plan_id = p_plan and (ms.end_date is null or ms.end_date >= (now() at time zone 'Australia/Perth')::date)
    order by ms.start_date desc limit 1;
  wk := coalesce(wk, p.weekly_price);
  st := coalesce(st, p_start, (now() at time zone 'Australia/Perth')::date);
  b := replace(p.agreement_body, '{price}', '$' || trim(to_char(wk, 'FM999990.00')));
  b := replace(b, '{start}', to_char(st, 'FMDay FMDD FMMonth YYYY'));
  b := replace(b, '{min_end}', case when p.min_weeks is null then 'n/a' else to_char(private.min_term_end(st, p.min_weeks), 'FMDay FMDD FMMonth YYYY') end);
  return jsonb_build_object('plan_id', p.id, 'plan', p.name, 'version', p.agreement_version, 'title', p.agreement_title,
    'body', b,
    'signed', (select jsonb_build_object('at', a.signed_at, 'name', a.signed_name) from public.membership_agreements a
               where a.profile_id = uid and a.plan_id = p.id and a.version = p.agreement_version order by a.signed_at desc limit 1));
end $$;
revoke execute on function public.agreement_for(uuid, date) from public, anon;
grant execute on function public.agreement_for(uuid, date) to authenticated;

-- Sign it. Keeps a copy of exactly what they agreed to. Links to their membership on that plan if they have one.
create or replace function public.sign_agreement(p_plan uuid, p_name text, p_agent text default null, p_start date default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare a jsonb; uid uuid := auth.uid(); rid uuid; mid uuid;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Type your full name to sign'; end if;
  a := public.agreement_for(p_plan, p_start);
  if a is null then raise exception 'There is no agreement for that membership'; end if;
  select id into mid from public.memberships where profile_id = uid and plan_id = p_plan
    and (end_date is null or end_date >= (now() at time zone 'Australia/Perth')::date) order by start_date desc limit 1;
  insert into public.membership_agreements (profile_id, plan_id, membership_id, version, title, body, signed_name, user_agent)
  values (uid, p_plan, mid, (a->>'version')::int, a->>'title', a->>'body', trim(p_name), left(p_agent, 300))
  returning id into rid;
  return rid;
end $$;
revoke execute on function public.sign_agreement(uuid, text, text, date) from public, anon;
grant execute on function public.sign_agreement(uuid, text, text, date) to authenticated;

-- My membership now also says whether the agreement is signed and when the minimum term ends.
create or replace function public.my_membership()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); today date := (now() at time zone 'Australia/Perth')::date; cur record; made timestamptz; can boolean;
begin
  if uid is null then return null; end if;
  select ms.id, ms.plan_id, ms.start_date, ms.end_date, ms.billing, ms.amount_paid, p.name, p.description, p.term_weeks, p.min_weeks,
         p.agreement_body is not null as has_agreement, p.agreement_version, p.early_cancel_fee,
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
      'min_weeks', cur.min_weeks, 'early_fee', cur.early_cancel_fee,
      'cooling_off_until', (select (min(a.signed_at) at time zone 'Australia/Perth')::date + 7 from public.membership_agreements a where a.membership_id = cur.id),
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

-- Athlete hold and cancel requests: 14 days' notice; whole weeks; minimum term (12 week plans: 30 days' notice + early
-- cancellation fee inside it; other plans: blocked, message Coach Ant); holds max 8 weeks a calendar year; 7 day cooling-off
-- after signing their agreement (cancel from today, no notice).
create or replace function public.request_hold_cancel(p_kind text, p_start date, p_end date, p_reason text)
returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare me uuid := auth.uid(); today date := (now() at time zone 'Australia/Perth')::date; first_ok date := today + 14;
  rid uuid; m record; mend date; used int; fee int; cool boolean := false;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if p_kind not in ('hold','cancel') then raise exception 'Choose hold or cancel'; end if;
  if p_start is null then raise exception 'Pick a week'; end if;
  select ms.id, ms.start_date, p.min_weeks, p.early_cancel_fee into m from public.memberships ms join public.membership_plans p on p.id = ms.plan_id
    where ms.profile_id = me and (ms.end_date is null or ms.end_date >= today)
    order by ms.start_date desc limit 1;
  if m.id is not null and p_kind = 'cancel' then
    cool := exists (select 1 from public.membership_agreements a where a.membership_id = m.id
                    having (min(a.signed_at) at time zone 'Australia/Perth')::date + 7 >= today);
  end if;
  if cool then
    if p_start < today then raise exception 'Pick today or a later day'; end if;
  else
    if p_start < first_ok then
      raise exception '14 days notice is required. The earliest date you can pick is %', to_char(first_ok, 'FMDay FMDD FMMonth');
    end if;
    if p_kind = 'hold' then
      if extract(isodow from p_start) <> 1 then raise exception 'Holds start on a Monday (memberships run in full weeks)'; end if;
      if p_end is null or p_end <= p_start or extract(isodow from p_end) <> 1 then raise exception 'Holds are in full weeks, back on a Monday'; end if;
    elsif extract(isodow from p_start) <> 7 then
      raise exception 'Cancellations finish at the end of a week, on a Sunday';
    end if;
    if m.min_weeks is not null then
      mend := private.min_term_end(m.start_date, m.min_weeks);
      if p_kind = 'cancel' and p_start < mend then
        if m.early_cancel_fee is null then
          raise exception 'Your % week minimum term runs until %, so that''s the earliest last day. If there''s a medical reason or you''re moving away, message Coach Ant.', m.min_weeks, to_char(mend, 'FMDay FMDD FMMonth');
        end if;
        if p_start < today + 30 then
          raise exception 'You''re inside your % week minimum term (until %). Cancelling before then needs 30 days notice, so the earliest last day is % (and there''s a $% early cancellation fee).',
            m.min_weeks, to_char(mend, 'FMDay FMDD FMMonth'), to_char(today + 30 + (7 - extract(isodow from today + 30)::int), 'FMDay FMDD FMMonth'), trim(to_char(m.early_cancel_fee, 'FM99990'));
        end if;
        fee := round(m.early_cancel_fee * 100);
      end if;
      if p_kind = 'hold' and p_start <= mend then
        raise exception 'Holds can''t start during your % week minimum term (until %). For medical or compassionate reasons, message Coach Ant.', m.min_weeks, to_char(mend, 'FMDay FMDD FMMonth');
      end if;
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
  insert into membership_requests (athlete_id, kind, start_date, end_date, reason, fee_cents)
  values (me, p_kind, p_start, case when p_kind = 'hold' then p_end end,
          nullif(trim(case when cool then 'Cooling-off. ' else '' end || coalesce(p_reason,'')), ''), fee)
  returning id into rid;
  return rid;
end; $$;

-- Early cancellation fee: once Ant approves, add it as a one-off payment for the next 6am run (billed through the app only;
-- Gymdesk-billed athletes he charges himself). Declining or undoing never charges it.
create or replace function private.request_fee() returns trigger
language plpgsql security definer set search_path = public as $$
declare ms record; md text; cid uuid; today date := (now() at time zone 'Australia/Perth')::date;
begin
  if new.kind = 'cancel' and new.status = 'approved' and coalesce(old.status, '') <> 'approved' and coalesce(new.fee_cents, 0) > 0 and new.fee_charge_id is null then
    select id, billing into ms from public.memberships where profile_id = new.athlete_id and (end_date is null or end_date >= today) order by start_date desc limit 1;
    if ms.id is null or ms.billing <> 'app' then return new; end if;
    select mode into md from public.billing_customers where profile_id = new.athlete_id order by updated_at desc limit 1;
    if md is null then return new; end if;
    insert into public.billing_charges (profile_id, membership_id, mode, bill_date, period_start, period_end, weeks, amount_cents, description)
    values (new.athlete_id, ms.id, md, today, new.start_date, new.start_date, 0, new.fee_cents, 'Rev Barbell Club: early cancellation fee')
    on conflict do nothing returning id into cid;
    if cid is not null then update public.membership_requests set fee_charge_id = cid where id = new.id; end if;
  end if;
  return new;
end $$;
create trigger membership_requests_fee after update of status on public.membership_requests for each row execute function private.request_fee();

-- WA Fitness Industry Code: remind athletes before their minimum term ends (3 weeks out), so they can cancel without a fee.
create or replace function private.min_term_reminders() returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0; today date := (now() at time zone 'Australia/Perth')::date; mend date;
begin
  for r in select ms.id, ms.profile_id, ms.start_date, p.min_weeks from public.memberships ms join public.membership_plans p on p.id = ms.plan_id
           where p.min_weeks is not null and ms.min_term_notified_at is null and ms.end_date is null loop
    mend := private.min_term_end(r.start_date, r.min_weeks);
    if today between mend - 21 and mend then
      perform private.push_out(array[r.profile_id], 'Your minimum term is nearly up',
        'Your ' || r.min_weeks || ' week minimum term ends ' || to_char(mend, 'FMDay FMDD FMMonth') || '. Your membership keeps going after that. To finish without a fee, request a cancellation in the app with 14 days notice.',
        'https://ant839.github.io/rev-app/#pay', null, 'minterm-' || r.id, null);
      update public.memberships set min_term_notified_at = now() where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
select cron.schedule('min-term-reminders', '0 1 * * *', $cron$ select private.min_term_reminders() $cron$);   -- 9am Perth

-- Waiver v2: Ant's Gymdesk Waiver and Release Agreement (loaded from the Gymdesk export), v1 retired.
