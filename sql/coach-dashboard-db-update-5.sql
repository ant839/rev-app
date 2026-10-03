-- Coach dashboard update 5 (3 Oct 2026): assign programs from the athlete calendar.
-- Both functions go through the builder's own roster/save logic, so the builder and the
-- dashboard always agree on who is on what.

-- Add, change or remove one athlete on a program's roster (Base / Competitive / FNDN, or an
-- Individual plan's own athlete). doc: { plan_id, athlete_id, days, strength, remove }
create or replace function public.coach_plan_roster(doc jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  plan uuid := nullif(doc->>'plan_id','')::uuid;
  ath uuid := nullif(doc->>'athlete_id','')::uuid;
  rm boolean := coalesce((doc->>'remove')::boolean, false);
  r jsonb; mem jsonb;
begin
  if not private.is_coach() then raise exception 'Only coaches can assign programs'; end if;
  if plan is null or ath is null then raise exception 'Pick a program and an athlete'; end if;
  select coalesce(roster, '{}'::jsonb) into r from program_plans where id = plan;
  if not found then raise exception 'That program no longer exists'; end if;
  select coalesce(jsonb_agg(m), '[]'::jsonb) into mem
    from jsonb_array_elements(coalesce(r->'members', '[]'::jsonb)) m where m->>'athlete_id' <> ath::text;
  if not rm then
    mem := mem || jsonb_build_array(jsonb_build_object('athlete_id', ath,
      'days', nullif(doc->>'days','')::int, 'strength', nullif(doc->>'strength','')));
  end if;
  r := jsonb_set(r, '{members}', mem, true);
  if not (r ? 'groups') then r := r || '{"groups":[]}'::jsonb; end if;
  update program_plans set roster = r, updated_at = now() where id = plan;
  return jsonb_build_object('ok', true, 'programs', private.builder_apply_roster(plan));
end;
$$;

-- Copy an Individual program for one athlete, starting on a chosen Monday (or, with no date,
-- the week it's assigned). The original is untouched. doc: { plan_id, athlete_id, start_date, name, publish }
create or replace function public.coach_copy_plan(doc jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  src uuid := nullif(doc->>'plan_id','')::uuid;
  ath uuid := nullif(doc->>'athlete_id','')::uuid;
  d jsonb; progs jsonb; res jsonb; newplan uuid;
begin
  if not private.is_coach() then raise exception 'Only coaches can assign programs'; end if;
  if src is null or ath is null then raise exception 'Pick a program and an athlete'; end if;
  d := private.builder_load_plan(src);
  if d is null then raise exception 'That program no longer exists'; end if;
  select coalesce(jsonb_agg(x - 'id' - 'assign' - 'locked' - 'status'), '[]'::jsonb) into progs
    from jsonb_array_elements(coalesce(d->'programs', '[]'::jsonb)) x;
  d := (d - 'id') || jsonb_build_object(
    'programs', progs,
    'name', coalesce(nullif(doc->>'name',''), d->>'name'),
    'athlete_id', ath,
    'start_date', nullif(doc->>'start_date',''),
    'versions', '[]'::jsonb,
    'roster', jsonb_build_object('groups', '[]'::jsonb,
      'members', jsonb_build_array(jsonb_build_object('athlete_id', ath, 'days', null, 'strength', null))));
  res := private.builder_save_plan(d);
  newplan := (res->>'plan_id')::uuid;
  if coalesce((doc->>'publish')::boolean, false) then
    update programs set status = 'published', updated_at = now() where plan_id = newplan and status <> 'archived';
  end if;
  return jsonb_build_object('ok', true, 'plan_id', newplan);
end;
$$;

grant execute on function public.coach_plan_roster(jsonb) to authenticated;
grant execute on function public.coach_copy_plan(jsonb) to authenticated;
