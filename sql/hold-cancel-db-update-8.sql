-- Update 8: hold and cancellation requests (13 Oct 2026)
-- Athletes send a request from the app's profile menu; it shows as Pending for them until the coach
-- approves or declines it from the coach dashboard. 14 days' notice is enforced here as well as in the app.
-- Safe to run twice.

create table if not exists public.membership_requests (
  id uuid primary key default gen_random_uuid(),
  athlete_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('hold','cancel')),
  start_date date not null,            -- hold: first day on hold; cancel: last day of membership
  end_date date,                       -- hold: back training from; cancel: null
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','declined','withdrawn')),
  coach_note text,
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (kind = 'cancel' or (end_date is not null and end_date > start_date))
);
create index if not exists membership_requests_athlete on public.membership_requests (athlete_id, created_at desc);
create unique index if not exists membership_requests_one_pending on public.membership_requests (athlete_id) where status = 'pending';

alter table public.membership_requests enable row level security;
-- read only: athletes see their own, coaches see all. All writes go through the functions below.
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'membership_requests' and policyname = 'mr_read') then
    create policy mr_read on public.membership_requests for select to authenticated
      using (athlete_id = (select auth.uid()) or (select private.is_coach()));
  end if;
end $p$;

-- athlete sends a request
create or replace function public.request_hold_cancel(p_kind text, p_start date, p_end date, p_reason text)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare me uuid := auth.uid(); first_ok date := ((now() at time zone 'Australia/Perth')::date + 14); rid uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  if p_kind not in ('hold','cancel') then raise exception 'Choose hold or cancel'; end if;
  if p_start is null then raise exception 'Pick a date'; end if;
  if p_start < first_ok then
    raise exception '14 days notice is required. The earliest date you can pick is %', to_char(first_ok, 'FMDay FMDD FMMonth');
  end if;
  if p_kind = 'hold' and (p_end is null or p_end <= p_start) then raise exception 'Pick a return date after the hold starts'; end if;
  if exists (select 1 from membership_requests where athlete_id = me and status = 'pending') then
    raise exception 'You already have a request waiting for Coach Ant';
  end if;
  insert into membership_requests (athlete_id, kind, start_date, end_date, reason)
  values (me, p_kind, p_start, case when p_kind = 'hold' then p_end end, nullif(trim(coalesce(p_reason,'')), ''))
  returning id into rid;
  return rid;
end; $$;

-- athlete takes back a pending request
create or replace function public.withdraw_hold_cancel(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update membership_requests set status = 'withdrawn', decided_at = now()
  where id = p_id and athlete_id = auth.uid() and status = 'pending';
  if not found then raise exception 'That request has already been dealt with'; end if;
end; $$;

-- coach approves or declines
create or replace function public.coach_decide_request(p_id uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  if p_decision not in ('approved','declined') then raise exception 'Approve or decline'; end if;
  update membership_requests set status = p_decision, coach_note = nullif(trim(coalesce(p_note,'')), ''),
    decided_by = auth.uid(), decided_at = now()
  where id = p_id and status = 'pending';
  if not found then raise exception 'That request has already been dealt with'; end if;
end; $$;

revoke all on function public.request_hold_cancel(text, date, date, text) from public, anon;
revoke all on function public.withdraw_hold_cancel(uuid) from public, anon;
revoke all on function public.coach_decide_request(uuid, text, text) from public, anon;
grant execute on function public.request_hold_cancel(text, date, date, text) to authenticated;
grant execute on function public.withdraw_hold_cancel(uuid) to authenticated;
grant execute on function public.coach_decide_request(uuid, text, text) to authenticated;

-- pings: a new request goes to coaches (switch 'requests' in the coach app); a decision goes to the athlete
create or replace function private.notify_request()
returns trigger language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare who uuid[]; nm text; what text;
begin
  what := case when new.kind = 'hold' then 'hold' else 'cancellation' end;
  if tg_op = 'INSERT' then
    select coalesce(nullif(full_name,''), email, 'An athlete') into nm from profiles where id = new.athlete_id;
    select array_agg(id) into who from profiles where role = 'coach' and id <> new.athlete_id;
    perform private.push_out(who, 'New ' || what || ' request',
      nm || case when new.kind = 'hold'
        then ' wants to hold from ' || to_char(new.start_date, 'FMDD Mon') || ' to ' || to_char(new.end_date, 'FMDD Mon')
        else ' wants to cancel, last day ' || to_char(new.start_date, 'FMDD Mon') end || '. Tap to approve.',
      null, 'https://ant839.github.io/rev-app/coach.html#home', 'request-' || new.id, 'requests');
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
end; $$;
create or replace trigger membership_requests_push after insert or update of status on public.membership_requests
  for each row execute function private.notify_request();

-- realtime so the coach dashboard shows new requests straight away
do $$ begin if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='membership_requests') then alter publication supabase_realtime add table public.membership_requests; end if; end $$;
