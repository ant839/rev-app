-- Update 9: forms (13 Oct 2026)
-- Coach builds a form, sends it to groups and/or athletes, now or scheduled, once or repeating.
-- Each athlete gets a form_requests row per round; they answer it in the app (pop-up, Home card,
-- push notification). Coaches see replies on the dashboard's Forms tab.
-- Drafts: anything Claude writes goes in as status 'draft' (forms and form_sends); nothing reaches
-- athletes until Ant sends it from the dashboard.
-- Safe to run twice.

create extension if not exists pg_cron;

-- ---------- tables ----------
create table if not exists public.forms (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Untitled form',
  intro text,
  -- [{id, type: short|long|choice|multi|scale|number|yesno|date, label, help, required, options[], min, max, low, high}]
  questions jsonb not null default '[]'::jsonb,
  status text not null default 'draft' check (status in ('draft','published','archived')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.form_sends (
  id uuid primary key default gen_random_uuid(),
  form_id uuid not null references public.forms(id) on delete cascade,
  group_ids uuid[] not null default '{}',
  athlete_ids uuid[] not null default '{}',
  late_joiners boolean not null default true,     -- athletes who join a target group later get the open round too
  repeat text not null default 'none' check (repeat in ('none','daily','weekly','fortnightly','monthly')),
  first_at timestamptz,                           -- first round (null on a draft = send as soon as it's sent)
  ends_on date,                                   -- repeating: last date a round can go out
  close_at timestamptz,                           -- one-off: stop taking replies after this (optional)
  next_at timestamptz,                            -- next round due (set when sent)
  last_round_at timestamptz,
  last_closes_at timestamptz,
  status text not null default 'draft' check (status in ('draft','active','paused','sent','ended')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists form_sends_due on public.form_sends (next_at) where status = 'active';

create table if not exists public.form_requests (
  id uuid primary key default gen_random_uuid(),
  send_id uuid not null references public.form_sends(id) on delete cascade,
  form_id uuid not null references public.forms(id) on delete cascade,
  athlete_id uuid not null references public.profiles(id) on delete cascade,
  round_at timestamptz not null,
  sent_at timestamptz not null default now(),
  closes_at timestamptz,
  nudged_at timestamptz,
  responded_at timestamptz,
  answers jsonb,                -- {question_id: value}
  snapshot jsonb,               -- the questions as they were when answered
  unique (send_id, athlete_id, round_at)
);
create index if not exists form_requests_athlete on public.form_requests (athlete_id, sent_at desc);
create index if not exists form_requests_send on public.form_requests (send_id, round_at);

-- ---------- RLS ----------
alter table public.forms enable row level security;
alter table public.form_sends enable row level security;
alter table public.form_requests enable row level security;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='forms' and policyname='forms_coach') then
    create policy forms_coach on public.forms for all to authenticated using ((select private.is_coach())) with check ((select private.is_coach()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='forms' and policyname='forms_athlete_read') then
    create policy forms_athlete_read on public.forms for select to authenticated
      using (status <> 'draft' and exists (select 1 from public.form_requests r where r.form_id = forms.id and r.athlete_id = (select auth.uid())));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='form_sends' and policyname='form_sends_coach') then
    create policy form_sends_coach on public.form_sends for all to authenticated using ((select private.is_coach())) with check ((select private.is_coach()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='form_requests' and policyname='form_requests_read') then
    create policy form_requests_read on public.form_requests for select to authenticated
      using (athlete_id = (select auth.uid()) or (select private.is_coach()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='form_requests' and policyname='form_requests_coach_write') then
    create policy form_requests_coach_write on public.form_requests for update to authenticated using ((select private.is_coach())) with check ((select private.is_coach()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='form_requests' and policyname='form_requests_coach_delete') then
    create policy form_requests_coach_delete on public.form_requests for delete to authenticated using ((select private.is_coach()));
  end if;
end $p$;

-- ---------- helpers ----------
-- who a send goes to: active athletes in its groups (coaches left out) plus anyone picked by name
create or replace function private.form_targets(p_send uuid)
returns setof uuid language sql stable security definer set search_path to 'public' as $$
  select distinct p.id from form_sends s
  join profiles p on p.active is not false and (
       p.id = any(s.athlete_ids)
    or (p.role <> 'coach' and exists (select 1 from group_members gm where gm.profile_id = p.id and gm.group_id = any(s.group_ids))))
  where s.id = p_send;
$$;

-- next round after t (Perth calendar, so weekly stays on the same weekday and time)
create or replace function private.form_next(t timestamptz, rep text)
returns timestamptz language sql immutable as $$
  select case rep
    when 'daily' then ((t at time zone 'Australia/Perth') + interval '1 day') at time zone 'Australia/Perth'
    when 'weekly' then ((t at time zone 'Australia/Perth') + interval '7 days') at time zone 'Australia/Perth'
    when 'fortnightly' then ((t at time zone 'Australia/Perth') + interval '14 days') at time zone 'Australia/Perth'
    when 'monthly' then ((t at time zone 'Australia/Perth') + interval '1 month') at time zone 'Australia/Perth'
    else null end;
$$;

-- give everyone in the send's audience a request for this round (if they don't have one) and ping the new ones
create or replace function private.form_fill_round(p_send uuid, p_round timestamptz, p_closes timestamptz)
returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare s record; f record; who uuid[]; n int; coach text;
begin
  select * into s from form_sends where id = p_send;
  select * into f from forms where id = s.form_id;
  with ins as (
    insert into form_requests (send_id, form_id, athlete_id, round_at, closes_at)
    select s.id, s.form_id, t, p_round, p_closes from private.form_targets(s.id) t
    on conflict (send_id, athlete_id, round_at) do nothing
    returning id, athlete_id)
  select array_agg(athlete_id), count(*) into who, n from ins;
  if n > 0 then
    select 'Coach ' || split_part(coalesce(nullif(full_name,''),'Ant'),' ',1) into coach from profiles where id = s.created_by;
    perform private.push_out(who, coalesce(f.title, 'New form'),
      coalesce(coach, 'Your coach') || ' has sent you a form. Tap to fill it in.',
      'https://ant839.github.io/rev-app/#forms', null, 'form-' || s.id, null);
  end if;
  return coalesce(n, 0);
end; $$;

-- runs every 5 minutes (pg_cron) and whenever someone opens the app: sends due rounds, adds late joiners
create or replace function private.run_due_form_sends()
returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare s record; nxt timestamptz; closes timestamptz; total int := 0;
begin
  -- rounds that are due
  for s in select * from form_sends where status = 'active' and next_at <= now() order by next_at for update skip locked loop
    nxt := private.form_next(s.next_at, s.repeat);
    -- skip rounds missed while nothing was running, so a late tick sends one round, not a backlog
    while nxt is not null and nxt <= now() loop
      nxt := private.form_next(nxt, s.repeat);
    end loop;
    if nxt is not null and s.ends_on is not null and (nxt at time zone 'Australia/Perth')::date > s.ends_on then nxt := null; end if;
    closes := case when s.repeat = 'none' then s.close_at else nxt end;
    -- the previous round of a repeating form closes when this one opens
    update form_requests set closes_at = s.next_at where send_id = s.id and round_at < s.next_at and (closes_at is null or closes_at > s.next_at);
    update form_sends set last_round_at = s.next_at, last_closes_at = closes, next_at = nxt,
      status = case when nxt is null then (case when s.repeat = 'none' then 'sent' else 'ended' end) else 'active' end,
      updated_at = now()
    where id = s.id;
    total := total + private.form_fill_round(s.id, s.next_at, closes);
  end loop;
  -- athletes who joined a target group after the round went out
  for s in select * from form_sends where late_joiners and cardinality(group_ids) > 0 and last_round_at is not null
             and status in ('active','sent','paused') and (last_closes_at is null or last_closes_at > now()) loop
    total := total + private.form_fill_round(s.id, s.last_round_at, s.last_closes_at);
  end loop;
  return total;
end; $$;

-- the app calls this on open, so nothing waits on the scheduler
create or replace function public.forms_tick() returns int
language sql security definer set search_path to 'public' as $$ select private.run_due_form_sends(); $$;
grant execute on function public.forms_tick() to authenticated;

-- coach sends (or schedules) a draft send; publishes the form too
create or replace function public.coach_send_form(p_send uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare s record; n int;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  select * into s from form_sends where id = p_send;
  if s.id is null then raise exception 'Send not found'; end if;
  if cardinality(s.group_ids) = 0 and cardinality(s.athlete_ids) = 0 then raise exception 'Pick at least one group or athlete'; end if;
  if s.repeat <> 'none' and s.ends_on is not null and coalesce(s.first_at, now()) > (s.ends_on + 1)::timestamp at time zone 'Australia/Perth' then
    raise exception 'The end date is before the first send'; end if;
  update forms set status = 'published', updated_at = now() where id = s.form_id and status = 'draft';
  update form_sends set status = 'active', first_at = coalesce(first_at, now()), next_at = greatest(coalesce(first_at, now()), now() - interval '1 minute'),
    created_by = coalesce(created_by, auth.uid()), updated_at = now() where id = p_send;
  n := private.run_due_form_sends();
  return jsonb_build_object('ok', true, 'sent', (select count(*) from form_requests where send_id = p_send),
    'next_at', (select next_at from form_sends where id = p_send));
end; $$;
grant execute on function public.coach_send_form(uuid) to authenticated;

-- coach pauses / resumes / ends a send
create or replace function public.coach_form_send_action(p_send uuid, p_action text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare s record; nxt timestamptz;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  select * into s from form_sends where id = p_send;
  if p_action = 'pause' and s.status = 'active' then
    update form_sends set status = 'paused', updated_at = now() where id = p_send;
  elsif p_action = 'resume' and s.status = 'paused' then
    nxt := s.next_at;
    while nxt is not null and nxt <= now() loop nxt := private.form_next(nxt, s.repeat); end loop;
    update form_sends set status = case when nxt is null then (case when s.repeat='none' then 'sent' else 'ended' end) else 'active' end,
      next_at = nxt, updated_at = now() where id = p_send;
  elsif p_action = 'end' then
    update form_sends set status = case when last_round_at is null then 'draft' else 'ended' end, next_at = null, updated_at = now() where id = p_send;
  elsif p_action = 'close' then   -- stop taking replies to the open round
    update form_requests set closes_at = now() where send_id = p_send and responded_at is null and (closes_at is null or closes_at > now());
    update form_sends set last_closes_at = now(), updated_at = now() where id = p_send;
  else raise exception 'Unknown action %', p_action; end if;
end; $$;
grant execute on function public.coach_form_send_action(uuid, text) to authenticated;

-- coach nudges athletes who haven't answered
create or replace function public.coach_nudge_form(p_ids uuid[])
returns int language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare who uuid[]; t text; sid uuid;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  select array_agg(distinct r.athlete_id), min(f.title), (array_agg(r.send_id))[1] into who, t, sid
    from form_requests r join forms f on f.id = r.form_id
    where r.id = any(p_ids) and r.responded_at is null and (r.closes_at is null or r.closes_at > now());
  if who is null then return 0; end if;
  update form_requests set nudged_at = now() where id = any(p_ids) and responded_at is null;
  perform private.push_out(who, 'Reminder: ' || coalesce(t, 'a form'), 'Coach Ant is waiting on your answers. Tap to fill it in.',
    'https://ant839.github.io/rev-app/#forms', null, 'form-' || sid, null);
  return cardinality(who);
end; $$;
grant execute on function public.coach_nudge_form(uuid[]) to authenticated;

-- athlete submits answers
create or replace function public.submit_form(p_request uuid, p_answers jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record; q jsonb; v jsonb;
begin
  select fr.*, f.questions into r from form_requests fr join forms f on f.id = fr.form_id where fr.id = p_request;
  if r.id is null or r.athlete_id <> auth.uid() then raise exception 'Form not found'; end if;
  if r.responded_at is not null then raise exception 'You''ve already sent this one'; end if;
  if r.closes_at is not null and r.closes_at <= now() then raise exception 'This form has closed'; end if;
  for q in select * from jsonb_array_elements(r.questions) loop
    if coalesce((q->>'required')::boolean, false) then
      v := p_answers -> (q->>'id');
      if v is null or v = 'null'::jsonb or v = '""'::jsonb or v = '[]'::jsonb then
        raise exception 'Please answer: %', q->>'label';
      end if;
    end if;
  end loop;
  update form_requests set answers = coalesce(p_answers, '{}'::jsonb), snapshot = r.questions, responded_at = now() where id = p_request;
end; $$;
grant execute on function public.submit_form(uuid, jsonb) to authenticated;

-- coaches get a ping when someone answers (switch "forms" in the coach app)
create or replace function private.notify_form_reply()
returns trigger language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare who uuid[]; t text; nm text;
begin
  if old.responded_at is not null or new.responded_at is null then return new; end if;
  select title into t from forms where id = new.form_id;
  select coalesce(nullif(full_name,''), 'An athlete') into nm from profiles where id = new.athlete_id;
  select array_agg(id) into who from profiles where role = 'coach' and id <> new.athlete_id;
  perform private.push_out(who, nm || ' filled in ' || coalesce('"' || t || '"', 'a form'), 'Tap to see their answers.',
    null, 'https://ant839.github.io/rev-app/coach.html#forms/' || new.send_id, 'formreply-' || new.send_id, 'forms');
  return new;
exception when others then
  raise warning 'form reply push failed: %', sqlerrm;
  return new;
end; $$;
create or replace trigger form_requests_reply_push after update of responded_at on public.form_requests
  for each row execute function private.notify_form_reply();

-- forms deleted with replies are archived instead (the dashboard decides; this keeps updated_at honest)
create or replace function private.forms_touch_updated() returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end; $$;
create or replace trigger forms_touch before update on public.forms for each row execute function private.forms_touch_updated();

-- scheduler: every 5 minutes
do $c$ begin
  perform cron.unschedule('rev-forms') where exists (select 1 from cron.job where jobname = 'rev-forms');
  perform cron.schedule('rev-forms', '*/5 * * * *', 'select private.run_due_form_sends()');
end $c$;
