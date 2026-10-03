-- Coach dashboard update 4 (3 Oct 2026): publish / unpublish sessions for one athlete.
-- An unpublished session stays on the coach's calendar but the athlete can't see it.
-- Shared program sessions are hidden per athlete without copying them.

create table if not exists public.session_hidden (
  athlete_id uuid not null references public.profiles(id) on delete cascade,
  session_id uuid not null references public.sessions(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (athlete_id, session_id)
);
create index if not exists session_hidden_session_idx on public.session_hidden(session_id);
alter table public.session_hidden enable row level security;
drop policy if exists coach_all on public.session_hidden;
create policy coach_all on public.session_hidden for all using (private.is_coach()) with check (private.is_coach());

create or replace function private.hidden_for_me(sid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists(select 1 from public.session_hidden where session_id = sid and athlete_id = auth.uid());
$$;

drop policy if exists not_hidden on public.sessions;
create policy not_hidden on public.sessions as restrictive for select
  using (private.is_coach() or not private.hidden_for_me(id));

-- doc: { athlete_id, session_ids: [...], hidden: true|false }
-- A personal version (replace) also hides the shared session it stands in for, so the
-- athlete doesn't fall back to seeing the shared one. Logged sessions are left visible.
create or replace function public.coach_set_hidden(doc jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  ath uuid := nullif(doc->>'athlete_id','')::uuid;
  hide boolean := coalesce((doc->>'hidden')::boolean, true);
  sid uuid; s sessions%rowtype; n int := 0; skipped int := 0;
begin
  if not private.is_coach() then raise exception 'Only coaches can publish sessions'; end if;
  if ath is null then raise exception 'No athlete chosen'; end if;
  for sid in select (jsonb_array_elements_text(coalesce(doc->'session_ids','[]'::jsonb)))::uuid loop
    select * into s from sessions where id = sid;
    if not found then continue; end if;
    if s.override_athlete_id is not null and s.override_athlete_id <> ath then raise exception 'That session belongs to another athlete'; end if;
    if hide then
      if exists(select 1 from workout_logs where session_id = sid and athlete_id = ath) then skipped := skipped + 1; continue; end if;
      insert into session_hidden(athlete_id, session_id) values (ath, sid) on conflict do nothing;
      if s.override_kind = 'replace' and s.replaces_session_id is not null then
        insert into session_hidden(athlete_id, session_id) values (ath, s.replaces_session_id) on conflict do nothing;
      end if;
    else
      delete from session_hidden where athlete_id = ath and (session_id = sid or session_id = s.replaces_session_id);
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'changed', n, 'skipped', skipped);
end;
$$;
grant execute on function public.coach_set_hidden(jsonb) to authenticated;
