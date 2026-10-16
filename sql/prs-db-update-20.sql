-- Update 20: PRs (Blackboard + PR Cards). Safe to run twice.
-- Blackboard: athletes opt in from Maxes (profiles.blackboard). blackboard() returns the current all-time max
--   (latest 'max' entry per lift, same rule as the app) for every active athlete who opted in.
-- PR Cards: pr_cards (lift, kilos, reps, previous best, note, optional video in the private 'prs' bucket),
--   visible to everyone signed in. pr_fistbumps: one fistbump per person per card, owner gets a push.

alter table public.profiles add column if not exists blackboard boolean not null default false;

create table if not exists public.pr_cards (
  id uuid primary key default gen_random_uuid(),
  athlete_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  athlete_name text,
  exercise_id uuid references public.exercises(id) on delete set null,
  lift_name text not null check (length(lift_name) between 1 and 80),
  weight_kg numeric check (weight_kg is null or (weight_kg > 0 and weight_kg < 1000)),
  reps integer not null default 1 check (reps between 1 and 100),
  previous_kg numeric,
  note text check (note is null or length(note) <= 300),
  video_path text,
  achieved_on date not null default current_date,
  created_at timestamptz not null default now()
);
create index if not exists pr_cards_created_idx on public.pr_cards (created_at desc);
create index if not exists pr_cards_athlete_idx on public.pr_cards (athlete_id);

create table if not exists public.pr_fistbumps (
  card_id uuid not null references public.pr_cards(id) on delete cascade,
  profile_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name text,
  created_at timestamptz not null default now(),
  primary key (card_id, profile_id)
);

create index if not exists pr_fistbumps_profile_idx on public.pr_fistbumps (profile_id);

alter table public.pr_cards enable row level security;
alter table public.pr_fistbumps enable row level security;

drop policy if exists prc_read on public.pr_cards;
create policy prc_read on public.pr_cards for select to authenticated using ((select auth.uid()) is not null);
drop policy if exists prc_insert on public.pr_cards;
create policy prc_insert on public.pr_cards for insert to authenticated with check (athlete_id = (select auth.uid()));
drop policy if exists prc_update on public.pr_cards;
create policy prc_update on public.pr_cards for update to authenticated using (athlete_id = (select auth.uid()) or private.is_coach()) with check (athlete_id = (select auth.uid()) or private.is_coach());
drop policy if exists prc_delete on public.pr_cards;
create policy prc_delete on public.pr_cards for delete to authenticated using (athlete_id = (select auth.uid()) or private.is_coach());

drop policy if exists prf_read on public.pr_fistbumps;
create policy prf_read on public.pr_fistbumps for select to authenticated using ((select auth.uid()) is not null);
drop policy if exists prf_insert on public.pr_fistbumps;
create policy prf_insert on public.pr_fistbumps for insert to authenticated with check (profile_id = (select auth.uid()));
drop policy if exists prf_delete on public.pr_fistbumps;
create policy prf_delete on public.pr_fistbumps for delete to authenticated using (profile_id = (select auth.uid()));

-- names filled in by the database (athletes can't read each other's profiles)
create or replace function private.pr_fill_name() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_table_name = 'pr_cards' then
    select coalesce(nullif(trim(full_name), ''), 'Athlete') into new.athlete_name from profiles where id = new.athlete_id;
  else
    select coalesce(nullif(trim(full_name), ''), 'Athlete') into new.name from profiles where id = new.profile_id;
  end if;
  return new;
end; $$;
drop trigger if exists pr_cards_name on public.pr_cards;
create trigger pr_cards_name before insert on public.pr_cards for each row execute function private.pr_fill_name();
drop trigger if exists pr_fistbumps_name on public.pr_fistbumps;
create trigger pr_fistbumps_name before insert on public.pr_fistbumps for each row execute function private.pr_fill_name();

-- push to the card's owner when someone fistbumps it (never your own)
create or replace function private.notify_fistbump() returns trigger
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare c record;
begin
  select athlete_id, lift_name, weight_kg, reps into c from pr_cards where id = new.card_id;
  if c.athlete_id is null or c.athlete_id = new.profile_id then return new; end if;
  perform private.push_out(array[c.athlete_id],
    coalesce(split_part(new.name, ' ', 1), 'Someone') || ' gave you a fistbump 👊',
    'On your ' || c.lift_name || coalesce(' PR, ' || trim(to_char(c.weight_kg, 'FM9990.##')) || ' kg', ' PR') ||
      case when c.reps > 1 then ' × ' || c.reps else '' end,
    'https://ant839.github.io/rev-app/#pr/' || new.card_id, null, 'pr-' || new.card_id, null);
  return new;
exception when others then
  raise warning 'fistbump push failed: %', sqlerrm;
  return new;
end; $$;
drop trigger if exists pr_fistbumps_push on public.pr_fistbumps;
create trigger pr_fistbumps_push after insert on public.pr_fistbumps for each row execute function private.notify_fistbump();

-- Blackboard: current all-time max per lift for athletes who opted in
create or replace function public.blackboard()
returns table(athlete_id uuid, name text, groups text[], exercise_id uuid, exercise_name text, weight_kg numeric, reps integer, recorded_on date)
language sql stable security definer set search_path to 'public' as $$
  select distinct on (m.athlete_id, m.exercise_id)
    m.athlete_id, coalesce(nullif(trim(p.full_name), ''), 'Athlete'),
    (select array_agg(g.name order by g.name) from group_members gm join groups g on g.id = gm.group_id where gm.profile_id = p.id),
    m.exercise_id, e.name, m.weight_kg, m.reps, m.recorded_on
  from athlete_maxes m
  join profiles p on p.id = m.athlete_id and p.blackboard and coalesce(p.active, true)
  join exercises e on e.id = m.exercise_id
  where m.kind = 'max' and auth.uid() is not null
  order by m.athlete_id, m.exercise_id, m.recorded_on desc, m.created_at desc;
$$;
revoke all on function public.blackboard() from public, anon;
grant execute on function public.blackboard() to authenticated;

-- PR videos: private bucket, anyone signed in can watch, athletes upload to their own folder
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('prs', 'prs', false, 52428800, array['video/mp4','video/quicktime','video/webm','video/3gpp','video/x-m4v'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists prs_read on storage.objects;
create policy prs_read on storage.objects for select to authenticated using (bucket_id = 'prs' and (select auth.uid()) is not null);
drop policy if exists prs_upload on storage.objects;
create policy prs_upload on storage.objects for insert to authenticated with check (bucket_id = 'prs' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists prs_delete on storage.objects;
create policy prs_delete on storage.objects for delete to authenticated using (bucket_id = 'prs' and ((storage.foldername(name))[1] = (select auth.uid())::text or private.is_coach()));

-- Update 21 (16 Oct, applied through the connector): coaches can make PR cards for any athlete
alter table public.pr_cards add column if not exists created_by uuid default auth.uid() references public.profiles(id) on delete set null;
alter policy prc_insert on public.pr_cards with check (athlete_id = (select auth.uid()) or private.is_coach());
drop policy if exists prs_coach_upload on storage.objects;
create policy prs_coach_upload on storage.objects for insert to authenticated with check (bucket_id = 'prs' and private.is_coach());
-- pr_fill_name now also sets created_by := auth.uid() on pr_cards; private.notify_pr_card_for + pr_cards_push
-- push the athlete "<coach first name> made you a PR card 🏆" when someone else made it.
