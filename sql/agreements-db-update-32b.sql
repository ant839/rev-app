-- Agreements db update 32 part 2 (17 Oct 2026): signing with a parent or guardian, photo consent, emailed copies.

-- Athletes can't change their own signing record directly; only the signing functions can (same rule now covers the new fields).
create or replace function private.guard_athlete_details() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  new.updated_at := now();
  if not private.is_coach() and coalesce(current_setting('rev.waiver_sign', true), '') <> '1' then
    if tg_op = 'INSERT' then
      new.waiver_id := null; new.waiver_version := null; new.waiver_signed_name := null; new.waiver_signed_at := null;
      new.waiver_guardian_name := null; new.waiver_guardian_relation := null; new.media_consent := null; new.media_consent_at := null;
    else
      new.waiver_id := old.waiver_id; new.waiver_version := old.waiver_version; new.waiver_signed_name := old.waiver_signed_name; new.waiver_signed_at := old.waiver_signed_at;
      new.waiver_guardian_name := old.waiver_guardian_name; new.waiver_guardian_relation := old.waiver_guardian_relation;
      new.media_consent := old.media_consent; new.media_consent_at := old.media_consent_at;
    end if;
  end if;
  return new;
end $$;

-- Under 18 from the date of birth on their profile (null when not given)
create or replace function private.is_minor(p uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select case when d.date_of_birth is null then null
              else d.date_of_birth > ((now() at time zone 'Australia/Perth')::date - interval '18 years') end
  from athlete_details d where d.profile_id = p;
$$;

create or replace function public.my_waiver() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('id', w.id, 'version', w.version, 'title', w.title, 'body', w.body,
    'signed_version', d.waiver_version, 'signed_at', d.waiver_signed_at, 'signed_name', d.waiver_signed_name,
    'guardian_name', d.waiver_guardian_name, 'guardian_relation', d.waiver_guardian_relation,
    'media_consent', d.media_consent, 'minor', private.is_minor(auth.uid()),
    'asks_media', w.body ilike '%When I sign, I choose whether%')
  from waivers w left join athlete_details d on d.profile_id = auth.uid()
  where w.active order by w.version desc limit 1;
$$;

drop function if exists public.sign_my_waiver(uuid, text);
create or replace function public.sign_my_waiver(p_waiver uuid, p_name text, p_guardian_relation text default null, p_media boolean default null)
returns timestamptz language plpgsql security definer set search_path to 'public' as $$
declare w waivers; t timestamptz := now(); g boolean := p_guardian_relation is not null and btrim(p_guardian_relation) <> '';
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select * into w from waivers where id = p_waiver and active;
  if w.id is null then raise exception 'That waiver has been updated. Reopen it and try again.'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Type your full name to sign'; end if;
  if private.is_minor(auth.uid()) and not g then raise exception 'You''re under 18, so a parent or guardian needs to sign. Tick the box and have them type their name.'; end if;
  perform set_config('rev.waiver_sign', '1', true);
  insert into athlete_details (profile_id, waiver_id, waiver_version, waiver_signed_name, waiver_signed_at,
                               waiver_guardian_name, waiver_guardian_relation, media_consent, media_consent_at)
  values (auth.uid(), w.id, w.version, btrim(p_name), t,
          case when g then left(btrim(p_name), 80) end, case when g then left(btrim(p_guardian_relation), 40) end,
          p_media, case when p_media is not null then t end)
  on conflict (profile_id) do update set waiver_id = excluded.waiver_id, waiver_version = excluded.waiver_version,
    waiver_signed_name = excluded.waiver_signed_name, waiver_signed_at = excluded.waiver_signed_at,
    waiver_guardian_name = excluded.waiver_guardian_name, waiver_guardian_relation = excluded.waiver_guardian_relation,
    media_consent = coalesce(excluded.media_consent, athlete_details.media_consent),
    media_consent_at = case when excluded.media_consent is not null then excluded.media_consent_at else athlete_details.media_consent_at end;
  perform set_config('rev.waiver_sign', '', true);
  return t;
end $$;
revoke all on function public.sign_my_waiver(uuid, text, text, boolean) from public, anon;
grant execute on function public.sign_my_waiver(uuid, text, text, boolean) to authenticated;

-- Change photo consent later (Profile)
create or replace function public.set_media_consent(p_ok boolean) returns boolean
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  perform set_config('rev.waiver_sign', '1', true);
  insert into athlete_details (profile_id, media_consent, media_consent_at) values (auth.uid(), p_ok, now())
  on conflict (profile_id) do update set media_consent = p_ok, media_consent_at = now();
  perform set_config('rev.waiver_sign', '', true);
  return p_ok;
end $$;
revoke all on function public.set_media_consent(boolean) from public, anon;
grant execute on function public.set_media_consent(boolean) to authenticated;

drop function if exists public.sign_agreement(uuid, text, text, date);
create or replace function public.sign_agreement(p_plan uuid, p_name text, p_agent text default null, p_start date default null, p_guardian_relation text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare a jsonb; uid uuid := auth.uid(); rid uuid; mid uuid; g boolean := p_guardian_relation is not null and btrim(p_guardian_relation) <> '';
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if length(trim(coalesce(p_name, ''))) < 3 then raise exception 'Type your full name to sign'; end if;
  if private.is_minor(uid) and not g then raise exception 'You''re under 18, so a parent or guardian needs to sign. Tick the box and have them type their name.'; end if;
  a := public.agreement_for(p_plan, p_start);
  if a is null then raise exception 'There is no agreement for that membership'; end if;
  select id into mid from public.memberships where profile_id = uid and plan_id = p_plan
    and (end_date is null or end_date >= (now() at time zone 'Australia/Perth')::date) order by start_date desc limit 1;
  insert into public.membership_agreements (profile_id, plan_id, membership_id, version, title, body, signed_name, user_agent, guardian_name, guardian_relation)
  values (uid, p_plan, mid, (a->>'version')::int, a->>'title', a->>'body', trim(p_name), left(p_agent, 300),
          case when g then left(trim(p_name), 80) end, case when g then left(btrim(p_guardian_relation), 40) end)
  returning id into rid;
  return rid;
end $$;
revoke all on function public.sign_agreement(uuid, text, text, date, text) from public, anon;
grant execute on function public.sign_agreement(uuid, text, text, date, text) to authenticated;

-- Agreements: say how the copy is given, and that a parent or guardian signs for under 18s
update public.membership_plans
set agreement_body = replace(agreement_body, E'\n\nThis agreement complies with the Fair Trading',
  E'\n\nIf I am under 18, my parent or guardian signs this agreement on my behalf.\n\nI will receive a copy of this signed agreement by email, I can view it in the Rev app at any time, and I can ask the Club for a paper copy.\n\nThis agreement complies with the Fair Trading')
where agreement_body like '%This agreement complies with the Fair Trading%' and agreement_body not like '%receive a copy of this signed agreement%';

-- ---------- Emailed copies ----------
-- One row per copy to send. The send-docs function sends them through Resend; rows wait (status pending) until email is set up.
create table if not exists public.doc_emails (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('waiver','agreement')),
  ref_id uuid,
  status text not null default 'pending' check (status in ('pending','sent','failed')),
  error text, attempts integer not null default 0,
  requested boolean not null default false,
  created_at timestamptz not null default now(), sent_at timestamptz
);
create index if not exists doc_emails_pending_idx on public.doc_emails (status, created_at) where status = 'pending';
create index if not exists doc_emails_profile_idx on public.doc_emails (profile_id);
alter table public.doc_emails enable row level security;
drop policy if exists de_read on public.doc_emails;
create policy de_read on public.doc_emails for select to authenticated using (profile_id = (select auth.uid()) or private.is_coach());

create or replace function private.doc_email_call() returns bigint
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare k text;
begin
  select value into k from private.app_config where key = 'records_sync_secret';  -- shared internal key for server-to-server calls
  return net.http_post(url := 'https://kaehtivwphtwoiaeszui.supabase.co/functions/v1/send-docs',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', k), body := '{}'::jsonb, timeout_milliseconds := 60000);
exception when others then raise warning 'doc email call failed: %', sqlerrm; return null;
end $$;

create or replace function private.queue_doc_email() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_table_name = 'membership_agreements' then
    insert into doc_emails (profile_id, kind, ref_id) values (new.profile_id, 'agreement', new.id);
  elsif new.waiver_signed_at is not null and (tg_op = 'INSERT' or new.waiver_signed_at is distinct from old.waiver_signed_at) then
    insert into doc_emails (profile_id, kind, ref_id) values (new.profile_id, 'waiver', new.waiver_id);
  end if;
  return new;
end $$;
drop trigger if exists membership_agreements_email on public.membership_agreements;
create trigger membership_agreements_email after insert on public.membership_agreements for each row execute function private.queue_doc_email();
drop trigger if exists athlete_details_waiver_email on public.athlete_details;
create trigger athlete_details_waiver_email after insert or update of waiver_signed_at on public.athlete_details for each row execute function private.queue_doc_email();

create or replace function private.doc_emails_kick() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin perform private.doc_email_call(); return null; end $$;
drop trigger if exists doc_emails_kick on public.doc_emails;
create trigger doc_emails_kick after insert on public.doc_emails for each statement execute function private.doc_emails_kick();

-- "Email me a copy" in the app
create or replace function public.email_my_copy(p_kind text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare uid uuid := auth.uid(); r uuid;
begin
  if uid is null then raise exception 'Sign in first'; end if;
  if p_kind = 'agreement' then select id into r from membership_agreements where profile_id = uid order by signed_at desc limit 1;
  elsif p_kind = 'waiver' then select waiver_id into r from athlete_details where profile_id = uid and waiver_signed_at is not null;
  else raise exception 'Unknown document'; end if;
  if r is null then raise exception 'You haven''t signed that yet'; end if;
  if exists (select 1 from doc_emails where profile_id = uid and kind = p_kind and created_at > now() - interval '10 minutes') then
    raise exception 'A copy is already on its way. Check your inbox (and junk folder) in a few minutes.'; end if;
  insert into doc_emails (profile_id, kind, ref_id, requested) values (uid, p_kind, r, true);
  return (select email from profiles where id = uid);
end $$;
revoke all on function public.email_my_copy(text) from public, anon;
grant execute on function public.email_my_copy(text) to authenticated;

-- Retry anything still waiting (e.g. sent before Resend was set up) every 30 minutes
select cron.schedule('doc-emails', '*/30 * * * *', $c$select private.doc_email_call() where exists (select 1 from public.doc_emails where status = 'pending')$c$);
