-- Memberships db update 28 (17 Oct 2026). Joining in the app.
-- Ant: athletes with no membership see "Join here!" (glowing) in the menu; once signed up it becomes "My membership".
-- Joinable plans: Barbell Club Gold, FNDN Gold, Platinum. Prices shown as "$X per week, billed fortnightly".
-- They pick a start date (next 2 weeks); first payment is the Wednesday of their first week (taken at sign up if that's already passed).
-- Goes straight through (no approval); coaches get a push.
-- Who can join for now: coaches (testing) and accounts made from 17 Oct 2026, with no current membership. Existing athletes
-- don't see Join because none of them have memberships loaded yet (they still pay through Gymdesk).

alter table public.membership_plans add column if not exists joinable boolean not null default false;
update public.membership_plans set joinable = true where name in ('Barbell Club Gold','FNDN Gold','Platinum');

create or replace function public.my_membership()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); today date := (now() at time zone 'Australia/Perth')::date; cur record; made timestamptz; can boolean;
begin
  if uid is null then return null; end if;
  select ms.id, ms.plan_id, ms.start_date, ms.end_date, ms.billing, ms.amount_paid, p.name, p.description, p.term_weeks,
         coalesce(ms.weekly_price, p.weekly_price) as weekly
    into cur
  from public.memberships ms join public.membership_plans p on p.id = ms.plan_id
  where ms.profile_id = uid and (ms.end_date is null or ms.end_date >= today)
  order by ms.start_date limit 1;
  select created_at into made from public.profiles where id = uid;
  can := cur.id is null and (private.is_coach() or made >= timestamptz '2026-10-17 00:00+08');
  return jsonb_build_object(
    'current', case when cur.id is null then null else jsonb_build_object('id', cur.id, 'plan', cur.name, 'description', cur.description,
      'start', cur.start_date, 'end', cur.end_date, 'billing', cur.billing, 'weekly', cur.weekly, 'lump', cur.term_weeks is not null,
      'amount_paid', cur.amount_paid,
      'on_hold', exists (select 1 from public.membership_requests r where r.athlete_id = uid and r.kind = 'hold' and r.status = 'approved'
                          and r.start_date <= today and r.end_date > today)) end,
    'can_join', can,
    'plans', case when can then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'program', program, 'description', description, 'weekly', weekly_price) order by sort)
                                          from public.membership_plans where joinable and active), '[]'::jsonb) else '[]'::jsonb end
  );
end $$;
revoke execute on function public.my_membership() from public, anon;
grant execute on function public.my_membership() to authenticated;

-- New member joined in the app: tell the coaches.
create or replace function private.notify_join() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare nm text; pl text; coaches uuid[];
begin
  if new.created_by is not null and new.created_by = new.profile_id and not private.is_coach() then
    select coalesce(nullif(full_name, ''), email) into nm from public.profiles where id = new.profile_id;
    select name into pl from public.membership_plans where id = new.plan_id;
    select array_agg(id) into coaches from public.profiles where role = 'coach';
    perform private.push_out(coaches, 'New membership', nm || ' joined ' || pl || ', starting ' || to_char(new.start_date, 'FMDy FMDD Mon'),
      null, 'https://ant839.github.io/rev-app/admin.html#memberships', 'join-' || new.id, 'payments');
  end if;
  return new;
exception when others then
  raise warning 'join push failed: %', sqlerrm; return new;
end $$;
create trigger memberships_notify_join after insert on public.memberships for each row execute function private.notify_join();
