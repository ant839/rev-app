-- Rev app: database update 6 (3 Oct 2026). Set Guide settings, technical vs strength lifts,
-- and a clean-up of duplicate exercises. Safe to run more than once.

-- 1. Each exercise is a technical lift or a strength lift (the Set Guide talks differently about each)
alter table public.exercises add column if not exists lift_type text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'exercises_lift_type_check') then
    alter table public.exercises add constraint exercises_lift_type_check check (lift_type in ('technical','strength'));
  end if;
end $$;

-- 2. Per-lift Set Guide settings from the builder: {"off":true} or {"start":75,"note":"Belt on from 100 kg"}
alter table public.session_exercises add column if not exists guide jsonb;

-- 3. Coach settings (the Set Guide numbers live under key 'set_guide'). Everyone signed in can read; coaches edit.
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
drop policy if exists read_settings on public.app_settings;
create policy read_settings on public.app_settings for select to authenticated using (true);
drop policy if exists coach_settings on public.app_settings;
create policy coach_settings on public.app_settings for all to authenticated using (private.is_coach()) with check (private.is_coach());
grant select, insert, update, delete on public.app_settings to authenticated;

-- 4. Duplicate exercises like "Hang Snatch (Knee) (% of Snatch)" (made by the builder's Claude panel)
--    are merged into "Hang Snatch (Knee)". Programs, maxes and links move across; nothing logged is lost.
do $$
declare d record; keep uuid; ofid uuid; clean text;
begin
  for d in select id, name from exercises where name ~ '\s\(% of [^)]+\)$' loop
    clean := regexp_replace(d.name, '\s\(% of [^)]+\)$', '');
    select id into keep from exercises where name = clean;
    select id into ofid from exercises where name = substring(d.name from '\(% of ([^)]+)\)$');
    if keep is null then
      update exercises set name = clean, default_percent_of = coalesce(default_percent_of, ofid) where id = d.id;
    else
      update session_exercises set exercise_id = keep where exercise_id = d.id;
      update session_exercises set percent_of = keep where percent_of = d.id;
      update athlete_maxes set exercise_id = keep where exercise_id = d.id;
      update exercises set default_percent_of = keep where default_percent_of = d.id;
      update exercises set default_percent_of = coalesce(default_percent_of, ofid) where id = keep and keep is distinct from ofid;
      delete from exercises where id = d.id;
    end if;
  end loop;
end $$;

-- 5. Snatch variations that were set to "% of Back Squat" by mistake go back to % of Snatch
update session_exercises se set percent_of = (select id from exercises where name = 'Snatch')
from exercises e
where e.id = se.exercise_id and e.name ilike '%snatch%' and e.name not ilike '%pull%'
  and se.percent_of = (select id from exercises where name = 'Back Squat')
  and exists (select 1 from exercises where name = 'Snatch');

-- 6. Starting lift types (change any of them in the builder's Exercises page)
update exercises set lift_type = case
    when name ~* '(pull|squat|deadlift|press|row|rdl|good ?morning|lunge|step|carry|plank|sled|curl|dip)' then 'strength'
    when name ~* '(snatch|clean|jerk)' or category in ('snatch','clean & jerk') then 'technical'
    else 'strength' end
where lift_type is null;

-- 7. The builder saves, loads and copies the per-lift guide; new exercise names never carry "(% of ...)"
create or replace function private.builder_write_items(sid uuid, items jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare it jsonb; st jsonb; seid uuid; exid uuid; ii int := 0; ji int; nm text;
begin
  delete from prescriptions where session_exercise_id in (select id from session_exercises where session_id = sid);
  delete from session_exercises where session_id = sid;
  for it in select value from jsonb_array_elements(coalesce(items, '[]'::jsonb)) loop
    exid := nullif(it->>'exercise_id','')::uuid;
    nm := trim(regexp_replace(coalesce(it->>'new_exercise',''), '\s\(% of [^)]+\)$', ''));
    if exid is null and nm <> '' then
      insert into exercises(name) values (nm)
      on conflict (name) do update set name = excluded.name returning id into exid;
    end if;
    continue when exid is null;
    insert into session_exercises(session_id, exercise_id, label, sort, percent_of, notes, hold_load, guide)
    values (sid, exid, nullif(it->>'label',''), ii, nullif(it->>'percent_of','')::uuid, nullif(it->>'notes',''), coalesce((it->>'hold')::boolean, false),
            case when jsonb_typeof(it->'guide') = 'object' and it->'guide' <> '{}'::jsonb then it->'guide' end)
    returning id into seid;
    ii := ii + 1; ji := 0;
    for st in select value from jsonb_array_elements(coalesce(it->'sets','[]'::jsonb)) loop
      insert into prescriptions(session_exercise_id, sort, sets, reps, percent, percent_max, load_kg, rpe, load_text, notes, warmup)
      values (seid, ji, coalesce(nullif(st->>'sets','')::int,1), coalesce(nullif(st->>'reps',''),'1'),
              nullif(st->>'percent','')::numeric, nullif(st->>'percent_max','')::numeric, nullif(st->>'load_kg','')::numeric,
              nullif(st->>'rpe','')::numeric, nullif(st->>'load_text',''), nullif(st->>'notes',''), coalesce((st->>'warmup')::boolean, false));
      ji := ji + 1;
    end loop;
  end loop;
end;
$$;

create or replace function private.copy_session_items(src uuid, dst uuid) returns void
language plpgsql security definer set search_path = public as $$
declare se record; nse uuid;
begin
  delete from prescriptions where session_exercise_id in (select id from session_exercises where session_id = dst);
  delete from session_exercises where session_id = dst;
  for se in select * from session_exercises where session_id = src order by sort loop
    insert into session_exercises(session_id, exercise_id, label, sort, percent_of, notes, hold_load, guide)
    values (dst, se.exercise_id, se.label, se.sort, se.percent_of, se.notes, se.hold_load, se.guide) returning id into nse;
    insert into prescriptions(session_exercise_id, sort, sets, reps, percent, percent_max, load_kg, rpe, rest_seconds, load_text, notes, warmup)
      select nse, sort, sets, reps, percent, percent_max, load_kg, rpe, rest_seconds, load_text, notes, warmup
      from prescriptions where session_exercise_id = se.id order by sort;
  end loop;
end;
$$;

create or replace function private.builder_load_program(pid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
select jsonb_build_object(
 'id',p.id,'name',p.name,'kind',p.kind,'track',p.track,'status',p.status,'is_template',p.is_template,'is_option',p.is_option,'days_version',p.days_version,'is_select',p.is_select,
 'locked', (select count(*) from sessions s where s.program_id = p.id and s.override_athlete_id is null and exists(select 1 from workout_logs w where w.session_id = s.id)),
 'assign', jsonb_build_object(
   'group_ids', coalesce((select jsonb_agg(group_id) from program_assignments where program_id = p.id and group_id is not null),'[]'::jsonb),
   'athlete_ids', coalesce((select jsonb_agg(athlete_id) from program_assignments where program_id = p.id and athlete_id is not null),'[]'::jsonb)),
 'sessions', coalesce((select jsonb_agg(jsonb_build_object(
    'week',s.week_number,'day',s.day_number,'title',s.title,'notes',s.notes,'code',s.code,
    'logged', exists(select 1 from workout_logs w where w.session_id = s.id),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'label',se.label,'exercise_id',se.exercise_id,'percent_of',se.percent_of,'notes',se.notes,'hold',se.hold_load,'guide',se.guide,
        'sets', coalesce((select jsonb_agg(jsonb_build_object('sets',pr.sets,'reps',pr.reps,'percent',pr.percent,'percent_max',pr.percent_max,'load_kg',pr.load_kg,'rpe',pr.rpe,'load_text',pr.load_text,'notes',pr.notes,'warmup',pr.warmup) order by pr.sort) from prescriptions pr where pr.session_exercise_id = se.id),'[]'::jsonb)
      ) order by se.sort) from session_exercises se where se.session_id = s.id),'[]'::jsonb)
  ) order by s.week_number, s.day_number, s.sort) from sessions s where s.program_id = p.id and s.override_athlete_id is null),'[]'::jsonb)
) from programs p where p.id = pid;
$$;

revoke all on function private.builder_write_items(uuid, jsonb) from public, anon, authenticated;
revoke all on function private.copy_session_items(uuid, uuid) from public, anon, authenticated;
revoke all on function private.builder_load_program(uuid) from public, anon, authenticated;
