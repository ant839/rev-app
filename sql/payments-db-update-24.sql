-- Payments db update 24 (16 Oct 2026). Athletes on memberships.billing = 'app' are charged through Stripe by the app.
-- Ant: billed fortnightly on Wednesdays; the Wednesday charge pays for the fortnight starting the Monday of that week.
-- Each athlete's fortnight lines up with memberships.bill_anchor (a Wednesday). Amount = weeks in the fortnight that are
-- inside the membership and not on hold x weekly price. Card and bank details live in Stripe only; we keep brand + last 4.

alter table public.memberships add column if not exists bill_anchor date check (bill_anchor is null or extract(isodow from bill_anchor) = 3);

create table if not exists public.billing_customers (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  mode text not null check (mode in ('test','live')),
  stripe_customer_id text not null,
  pm_id text,
  pm_type text,            -- card | au_becs_debit
  pm_brand text,           -- visa, mastercard, or the bank name
  pm_last4 text,
  pm_exp text,             -- MM/YY for cards
  updated_at timestamptz not null default now(),
  primary key (profile_id, mode)
);
alter table public.billing_customers enable row level security;
create policy billing_customers_read on public.billing_customers for select to authenticated using (private.is_coach() or profile_id = auth.uid());

create table if not exists public.billing_charges (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  membership_id uuid not null references public.memberships(id),
  mode text not null check (mode in ('test','live')),
  bill_date date not null,
  period_start date not null,
  period_end date not null,
  weeks integer not null,
  amount_cents integer not null check (amount_cents >= 0),
  description text,
  status text not null default 'pending' check (status in ('pending','processing','succeeded','failed','skipped','refunded')),
  stripe_pi text,
  failure text,
  attempts integer not null default 0,
  notified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (membership_id, period_start, mode)
);
create index if not exists billing_charges_profile_idx on public.billing_charges (profile_id, bill_date desc);
alter table public.billing_charges enable row level security;
create policy billing_charges_read on public.billing_charges for select to authenticated using (private.is_coach() or profile_id = auth.uid());
alter publication supabase_realtime add table public.billing_charges;

-- What a membership owes for the fortnight that starts on p_monday.
create or replace function private.billing_calc(p_membership uuid, p_monday date)
returns table (weeks integer, amount_cents integer, weekly numeric, plan_name text)
language sql stable security definer set search_path = public as $$
  with m as (
    select ms.*, p.name as plan_name, coalesce(ms.weekly_price, p.weekly_price) as wk, p.term_weeks
    from public.memberships ms join public.membership_plans p on p.id = ms.plan_id where ms.id = p_membership
  ), w as (
    select (p_monday + i * 7) as wk_monday from generate_series(0, 1) i
  )
  select count(*)::int,
         (count(*) * round((select wk from m) * 100))::int,
         (select wk from m), (select plan_name from m)
  from w, m
  where m.term_weeks is null
    and w.wk_monday + 6 >= m.start_date                         -- membership started by that week's Sunday
    and (m.end_date is null or w.wk_monday <= m.end_date)       -- not past the last day
    and not exists (select 1 from public.membership_requests r
                    where r.athlete_id = m.profile_id and r.kind = 'hold' and r.status = 'approved'
                      and r.start_date <= w.wk_monday and r.end_date > w.wk_monday);
$$;

-- Memberships billed by the app that are due on p_date (a Wednesday on their fortnight).
create or replace function public.billing_due(p_date date)
returns table (membership_id uuid, profile_id uuid, bill_date date, period_start date, period_end date, weeks integer, amount_cents integer, description text)
language sql stable security definer set search_path = public as $$
  select ms.id, ms.profile_id, p_date, p_date - 2, p_date + 11, c.weeks, c.amount_cents,
    'Rev Barbell Club: ' || c.plan_name || ', ' || to_char(p_date - 2, 'FMDD Mon') || ' to ' || to_char(p_date + 11, 'FMDD Mon')
  from public.memberships ms
  cross join lateral private.billing_calc(ms.id, p_date - 2) c
  where ms.billing = 'app' and ms.bill_anchor is not null
    and extract(isodow from p_date) = 3
    and p_date >= ms.bill_anchor and (p_date - ms.bill_anchor) % 14 = 0
    and ms.start_date <= p_date + 11
    and (ms.end_date is null or ms.end_date >= p_date - 2);
$$;
revoke execute on function public.billing_due(date) from public, anon, authenticated;
grant execute on function public.billing_due(date) to service_role;

-- Next charge for a membership (coach, or the athlete themselves).
create or replace function public.billing_next(p_membership uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ms public.memberships; d date; today date := (now() at time zone 'Australia/Perth')::date; c record; i int := 0;
begin
  select * into ms from public.memberships where id = p_membership;
  if ms.id is null or not (private.is_coach() or ms.profile_id = auth.uid()) then return null; end if;
  if ms.billing <> 'app' or ms.bill_anchor is null then return null; end if;
  d := ms.bill_anchor;
  if d < today then d := d + (((today - d) + 13) / 14) * 14; end if;
  loop
    exit when i > 26;
    if ms.end_date is not null and d - 2 > ms.end_date then return jsonb_build_object('ended', true); end if;
    select * into c from private.billing_calc(ms.id, d - 2);
    if c.weeks > 0 and not exists (select 1 from public.billing_charges b where b.membership_id = ms.id and b.period_start = d - 2 and b.status in ('succeeded','processing')) then
      return jsonb_build_object('bill_date', d, 'period_start', d - 2, 'period_end', d + 11, 'weeks', c.weeks, 'amount_cents', c.amount_cents);
    end if;
    d := d + 14; i := i + 1;
  end loop;
  return null;
end $$;
grant execute on function public.billing_next(uuid) to authenticated;

-- Failed payment: tell the athlete (opens their Payments screen) and the coaches.
create or replace function private.notify_charge() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare nm text; coaches uuid[];
begin
  if new.status = 'failed' and (old.status is distinct from 'failed') then
    select coalesce(nullif(full_name, ''), email) into nm from public.profiles where id = new.profile_id;
    perform private.push_out(array[new.profile_id], 'Your payment didn''t go through',
      'Your $' || to_char(new.amount_cents / 100.0, 'FM999990.00') || ' membership payment failed. Tap to check your card.',
      'https://ant839.github.io/rev-app/#pay', null, 'pay-' || new.id, null);
    select array_agg(id) into coaches from public.profiles where role = 'coach';
    perform private.push_out(coaches, 'Payment failed', nm || ': $' || to_char(new.amount_cents / 100.0, 'FM999990.00') || coalesce(' (' || left(new.failure, 80) || ')', ''),
      null, 'https://ant839.github.io/rev-app/admin.html#memberships', 'payfail-' || new.id, 'payments');
  end if;
  return new;
exception when others then
  raise warning 'charge push failed: %', sqlerrm; return new;
end $$;
create trigger billing_charges_notify after update of status on public.billing_charges for each row execute function private.notify_charge();

-- Daily at 6am Perth (22:00 UTC): charge whoever is due today (Wednesdays) and check on bank debits still processing.
select cron.schedule('billing-tick', '0 22 * * *', $cron$
  select net.http_post(url := 'https://kaehtivwphtwoiaeszui.supabase.co/functions/v1/billing-tick',
    headers := jsonb_build_object('Content-Type','application/json','x-hook-secret', (select value from private.app_config where key = 'push_hook_secret')),
    body := '{}'::jsonb)
$cron$);

-- 16 Oct 2026: Ant doesn't want direct debit. Cards only (BECS Direct Debit stays off in Stripe > Settings > Payment methods).
