-- Memberships db update 22 (REV Admin). Plans, each athlete's membership, and holds/cancellations moved here from Rev Coach.
-- Billing still runs in Gymdesk: this is the record of who is on what, from when, and what they pay.
-- Status is worked out, not stored: Cancelled (end date passed), On hold (an approved hold covers today),
-- Cancelling (end date set, still in the future), Hold booked (approved hold coming up), Active.

create table if not exists public.membership_plans (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  program text not null check (program in ('barbell','fndn','pt','other')),
  weekly_price numeric(8,2) not null check (weekly_price >= 0),
  description text,
  active boolean not null default true,
  sort integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.membership_plans enable row level security;
create policy membership_plans_coach_read on public.membership_plans for select to authenticated using (private.is_coach());
create policy membership_plans_coach_insert on public.membership_plans for insert to authenticated with check (private.is_coach());
create policy membership_plans_coach_update on public.membership_plans for update to authenticated using (private.is_coach()) with check (private.is_coach());

insert into public.membership_plans (name, program, weekly_price, description, sort)
select * from (values
  ('Barbell Club', 'barbell', 60.00, 'Standard weekly membership', 10),
  ('Barbell Club Gold', 'barbell', 70.00, null, 20),
  ('Barbell Club 3 Day', 'barbell', 50.00, 'Up to 3 sessions a week', 30),
  ('FNDN Unlimited', 'fndn', 65.00, 'Unlimited classes, open gym access 4am to 10pm', 40)
) v(name, program, weekly_price, description, sort)
where not exists (select 1 from public.membership_plans);

create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  plan_id uuid not null references public.membership_plans(id),
  start_date date not null,
  end_date date,                                   -- last day (a Sunday) once cancelling
  weekly_price numeric(8,2),                       -- set only if different from the plan
  billing text not null default 'gymdesk' check (billing in ('gymdesk','app','none')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  check (end_date is null or end_date >= start_date)
);
create index if not exists memberships_profile_idx on public.memberships (profile_id, start_date desc);
alter table public.memberships enable row level security;
create policy memberships_read on public.memberships for select to authenticated using (private.is_coach() or profile_id = auth.uid());
create policy memberships_coach_insert on public.memberships for insert to authenticated with check (private.is_coach());
create policy memberships_coach_update on public.memberships for update to authenticated using (private.is_coach()) with check (private.is_coach());
alter publication supabase_realtime add table public.memberships;

-- Approving a cancellation sets the end date on their current membership.
create or replace function private.request_to_membership() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'cancel' and new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved') then
    update public.memberships m set end_date = new.start_date, updated_at = now()
    where m.id = (select id from public.memberships where profile_id = new.athlete_id and (end_date is null or end_date >= current_date)
                  order by start_date desc limit 1)
      and new.start_date >= m.start_date;
  end if;
  return new;
end $$;
create trigger membership_requests_to_membership after insert or update of status on public.membership_requests
  for each row execute function private.request_to_membership();

-- Coach adds a hold or cancellation directly (athlete asked in person). Approved straight away, no 14 day rule,
-- but still whole weeks: holds Monday to Monday, cancellations end on a Sunday.
create or replace function public.coach_add_request(p_athlete uuid, p_kind text, p_start date, p_end date, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  if p_kind not in ('hold','cancel') then raise exception 'Hold or cancel'; end if;
  if p_kind = 'hold' then
    if p_end is null or p_end <= p_start then raise exception 'Pick when the hold ends'; end if;
    if extract(isodow from p_start) <> 1 or extract(isodow from p_end) <> 1 then raise exception 'Holds run whole weeks, Monday to Monday'; end if;
  else
    if extract(isodow from p_start) <> 7 then raise exception 'Cancellations finish on a Sunday'; end if;
  end if;
  update public.membership_requests set status = 'withdrawn', decided_at = now(), decided_by = auth.uid()
    where athlete_id = p_athlete and status = 'pending';
  insert into public.membership_requests (athlete_id, kind, start_date, end_date, reason, status, coach_note, decided_by, decided_at)
    values (p_athlete, p_kind, p_start, case when p_kind = 'hold' then p_end end, 'Added by coach', 'approved',
            nullif(trim(coalesce(p_note, '')), ''), auth.uid(), now())
  returning id into rid;
  return rid;
end $$;

-- Coach undoes an approved hold or cancellation (changed their mind). Cancelling one also clears the membership end date.
create or replace function public.coach_undo_request(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare r public.membership_requests;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  select * into r from public.membership_requests where id = p_id;
  if r.id is null or r.status <> 'approved' then raise exception 'Only approved holds or cancellations can be undone'; end if;
  update public.membership_requests set status = 'withdrawn', coach_note = coalesce(coach_note || ' ', '') || '(undone by coach)' where id = p_id;
  if r.kind = 'cancel' then
    update public.memberships set end_date = null, updated_at = now() where profile_id = r.athlete_id and end_date = r.start_date;
  end if;
end $$;

revoke execute on function public.coach_add_request(uuid, text, date, date, text) from public, anon;
revoke execute on function public.coach_undo_request(uuid) from public, anon;
grant execute on function public.coach_add_request(uuid, text, date, date, text) to authenticated;
grant execute on function public.coach_undo_request(uuid) to authenticated;

-- New hold/cancel request notifications now open REV Admin.
create or replace function private.notify_request()
returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare who uuid[]; nm text; what text;
begin
  what := case when new.kind = 'hold' then 'hold' else 'cancellation' end;
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then return new; end if;   -- added by a coach: no ping
    select coalesce(nullif(full_name,''), email, 'An athlete') into nm from profiles where id = new.athlete_id;
    select array_agg(id) into who from profiles where role = 'coach' and id <> new.athlete_id;
    perform private.push_out(who, 'New ' || what || ' request',
      nm || case when new.kind = 'hold'
        then ' wants to hold from ' || to_char(new.start_date, 'FMDD Mon') || ' to ' || to_char(new.end_date, 'FMDD Mon')
        else ' wants to cancel, last day ' || to_char(new.start_date, 'FMDD Mon') end || '. Tap to approve.',
      null, 'https://ant839.github.io/rev-app/admin.html#memberships', 'request-' || new.id, 'requests');
  elsif old.status = 'pending' and new.status in ('approved','declined') then
    perform private.push_out(array[new.athlete_id],
      'Your ' || what || ' request was ' || new.status,
      coalesce(new.coach_note, case when new.status = 'approved' then 'Coach Ant has approved it.' else 'Message Coach Ant if you have questions.' end),
      'https://ant839.github.io/rev-app/', null, 'request-' || new.id, null);
  end if;
  return new;
exception when others then
  raise warning 'request push failed: %', sqlerrm;
  return new;
end $$;
