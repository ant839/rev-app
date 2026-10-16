-- Repeat weekly (16 Oct 2026). Ant asked for a "repeat weekly" option so a program like Free Trial runs forever.
-- programs.repeat_weekly: week 1 is the template. private.repeat_sync keeps real copies of week 1 from last week
-- to 8 weeks ahead (so logs, history, the coach calendar and the athlete app work exactly as for any program).
-- Unlogged copies are refreshed from week 1 every sync, so editing week 1 updates every upcoming week.
-- Logged sessions, and sessions an athlete or coach has touched (notes, videos, hidden, personal replacements), are never removed.
-- Runs nightly (pg_cron 'repeat-weekly', 00:05 Perth), after every builder save, and when the switch is turned on.

alter table public.programs add column if not exists repeat_weekly boolean not null default false;

-- Content fingerprint of a session (title, notes, code, every lift and line), used to spot copies that no longer match week 1
create or replace function private.session_fp(sid uuid)
returns text language sql stable security definer set search_path to 'public' as $$
  select md5(coalesce(s.title,'') || '|' || coalesce(s.notes,'') || '|' || coalesce(s.code,'') || '|' || coalesce((
    select string_agg(concat_ws('^', se.sort, se.label, se.exercise_id, se.percent_of, se.notes, se.hold_load, se.guide::text, (
      select string_agg(concat_ws('~', pr.sort, pr.sets, pr.reps, pr.percent, pr.percent_max, pr.load_kg, pr.rpe, pr.rest_seconds, pr.notes, pr.load_text, pr.warmup), ';' order by pr.sort)
      from prescriptions pr where pr.session_exercise_id = se.id)), '#' order by se.sort)
    from session_exercises se where se.session_id = s.id), ''))
  from sessions s where s.id = sid;
$$;

create or replace function private.repeat_sync(pid uuid)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare p record; cur int; lo int; hi int; w int; tpl record; e record; nsid uuid; nseid uuid; made int := 0;
begin
  select * into p from programs where id = pid;
  if p.id is null or not p.repeat_weekly or p.status = 'archived' or p.start_date is null then return 0; end if;
  cur := greatest(1, floor(((now() at time zone 'Australia/Perth')::date - p.start_date) / 7.0)::int + 1);
  lo := greatest(2, cur - 1); hi := cur + 8;

  -- clear untouched copies (weeks 2+) that are outside the window or no longer match week 1; the window is then filled from week 1
  delete from sessions s
  where s.program_id = pid and s.override_athlete_id is null and s.week_number >= 2
    and (s.week_number < lo or s.week_number > hi or private.session_fp(s.id) is distinct from
         (select private.session_fp(t.id) from sessions t where t.program_id = pid and t.override_athlete_id is null and t.week_number = 1 and t.day_number = s.day_number order by t.sort limit 1))
    and not exists(select 1 from workout_logs x where x.session_id = s.id)
    and not exists(select 1 from athlete_notes x where x.session_id = s.id)
    and not exists(select 1 from video_reviews x where x.session_id = s.id)
    and not exists(select 1 from session_hidden x where x.session_id = s.id)
    and not exists(select 1 from sessions x where x.replaces_session_id = s.id);

  for w in lo..hi loop
    for tpl in select * from sessions where program_id = pid and week_number = 1 and override_athlete_id is null order by day_number, sort loop
      continue when exists(select 1 from sessions where program_id = pid and override_athlete_id is null and week_number = w and day_number = tpl.day_number);
      insert into sessions(program_id, week_number, day_number, title, notes, code, sort, scheduled_date)
      values (pid, w, tpl.day_number, tpl.title, tpl.notes, tpl.code, tpl.sort + w * 10, p.start_date + ((w - 1) * 7 + tpl.day_number - 1))
      returning id into nsid;
      made := made + 1;
      for e in select * from session_exercises where session_id = tpl.id order by sort loop
        insert into session_exercises(session_id, exercise_id, label, sort, percent_of, notes, hold_load, guide)
        values (nsid, e.exercise_id, e.label, e.sort, e.percent_of, e.notes, e.hold_load, e.guide) returning id into nseid;
        insert into prescriptions(session_exercise_id, sort, sets, reps, percent, percent_max, load_kg, rpe, rest_seconds, notes, load_text, warmup)
        select nseid, sort, sets, reps, percent, percent_max, load_kg, rpe, rest_seconds, notes, load_text, warmup
        from prescriptions where session_exercise_id = e.id;
      end loop;
    end loop;
  end loop;

  -- keep a one-block plan's length in step so the builder and dashboard cover the running weeks
  update program_plans pl set total_weeks = greatest(hi, coalesce((select max(week_number) from sessions where program_id = pid), hi)),
    blocks = jsonb_set(pl.blocks, '{0,weeks}', to_jsonb(greatest(hi, coalesce((select max(week_number) from sessions where program_id = pid), hi))))
  where pl.id = p.plan_id and jsonb_array_length(pl.blocks) = 1;
  return made;
end; $$;

create or replace function private.repeat_sync_all()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare r record; n int := 0;
begin
  for r in select id from programs where repeat_weekly and status <> 'archived' loop
    n := n + private.repeat_sync(r.id);
  end loop;
  return n;
end; $$;

-- Coach switch (Programs page): turn repeat weekly on or off for one program
create or replace function public.coach_set_repeat(pid uuid, on_off boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare made int := 0; sd date;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  select start_date into sd from programs where id = pid;
  if on_off and sd is null then
    -- needs a start date to know which week it is; use this Monday (Perth)
    sd := date_trunc('week', (now() at time zone 'Australia/Perth')::date)::date;
    update programs set start_date = sd where id = pid;
    update sessions set scheduled_date = sd + ((week_number - 1) * 7 + day_number - 1)
      where program_id = pid and override_athlete_id is null and scheduled_date is null;
  end if;
  update programs set repeat_weekly = on_off, updated_at = now() where id = pid;
  if on_off then made := private.repeat_sync(pid); end if;
  return jsonb_build_object('ok', true, 'repeat_weekly', on_off, 'added', made);
end; $$;
grant execute on function public.coach_set_repeat(uuid, boolean) to authenticated;

-- After every builder save, re-sync the plan's repeating programs (week 1 edits flow to the upcoming weeks)
create or replace function private.builder_save_plan(doc jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare plan uuid; p jsonb; out jsonb := '[]'::jsonb; blk int; wk_offset int; start_on date; b jsonb; i int; rp record;
begin
  plan := nullif(doc->>'id','')::uuid;
  if plan is not null and not exists(select 1 from program_plans where id = plan) then plan := null; end if;
  if plan is null then
    insert into program_plans(name, plan_type, athlete_id, start_date, total_weeks, training_days, goals, code_prefix, blocks, versions, roster)
    values (coalesce(nullif(doc->>'name',''),'Untitled program'), coalesce(nullif(doc->>'plan_type',''),'BASE'),
            nullif(doc->>'athlete_id','')::uuid, nullif(doc->>'start_date','')::date, coalesce((doc->>'total_weeks')::int,4),
            coalesce((select array_agg(x::int) from jsonb_array_elements_text(doc->'training_days') x),'{1,2,3,5}'),
            nullif(doc->>'goals',''), nullif(doc->>'code_prefix',''), coalesce(doc->'blocks','[]'::jsonb),
            coalesce(doc->'versions','[]'::jsonb), coalesce(doc->'roster','{}'::jsonb))
    returning id into plan;
  else
    update program_plans set name = coalesce(nullif(doc->>'name',''),'Untitled program'), plan_type = coalesce(nullif(doc->>'plan_type',''),'BASE'),
      athlete_id = nullif(doc->>'athlete_id','')::uuid, start_date = nullif(doc->>'start_date','')::date,
      total_weeks = coalesce((doc->>'total_weeks')::int,4),
      training_days = coalesce((select array_agg(x::int) from jsonb_array_elements_text(doc->'training_days') x),'{1,2,3,5}'),
      goals = nullif(doc->>'goals',''), code_prefix = nullif(doc->>'code_prefix',''), blocks = coalesce(doc->'blocks','[]'::jsonb),
      versions = coalesce(doc->'versions','[]'::jsonb), roster = coalesce(doc->'roster', roster), updated_at = now()
    where id = plan;
  end if;

  for p in select value from jsonb_array_elements(coalesce(doc->'programs','[]'::jsonb)) loop
    blk := coalesce((p->>'block_index')::int, 0);
    wk_offset := 0; i := 0;
    for b in select value from jsonb_array_elements(coalesce(doc->'blocks','[]'::jsonb)) loop
      exit when i >= blk;
      wk_offset := wk_offset + coalesce((b->>'weeks')::int,0); i := i + 1;
    end loop;
    start_on := case when nullif(doc->>'start_date','') is null then null else (doc->>'start_date')::date + wk_offset * 7 end;
    out := out || jsonb_build_array(private.builder_save_program(p, plan, blk, start_on, wk_offset) || jsonb_build_object('block_index', blk));
  end loop;

  perform private.builder_apply_roster(plan);
  for rp in select id from programs where plan_id = plan and repeat_weekly and status <> 'archived' loop
    perform private.repeat_sync(rp.id);
  end loop;
  return jsonb_build_object('plan_id', plan, 'saved', out);
end;
$function$;

-- Nightly top-up at 00:05 Perth (16:05 UTC)
select cron.schedule('repeat-weekly', '5 16 * * *', $$select private.repeat_sync_all()$$);
