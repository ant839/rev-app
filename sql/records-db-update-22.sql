-- Update 22: Club record board (PRs > Records). Safe to run twice.
-- Coach-entered senior club records for Snatch, Clean & Jerk and Total in the current IWF categories
-- (from 1 June 2025: men 60 65 71 79 88 94 110 +110, women 48 53 58 63 69 77 86 +86).
-- Every entry is kept as history; the current record for a category and lift is the heaviest (earliest date wins a tie).
-- Everyone signed in can read; only coaches can add, change or delete.

create table if not exists public.club_records (
  id uuid primary key default gen_random_uuid(),
  sex text not null check (sex in ('male','female')),
  category text not null check (category in ('60','65','71','79','88','94','110','+110','48','53','58','63','69','77','86','+86')),
  lift text not null check (lift in ('snatch','cj','total')),
  weight_kg numeric not null check (weight_kg > 0 and weight_kg < 600),
  athlete_id uuid references public.profiles(id) on delete set null,
  lifter_name text not null check (length(trim(lifter_name)) between 1 and 80),
  set_on date not null default current_date,
  competition text check (competition is null or length(competition) <= 120),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists club_records_board_idx on public.club_records (sex, category, lift, weight_kg desc, set_on);
create index if not exists club_records_athlete_idx on public.club_records (athlete_id);
create index if not exists club_records_created_by_idx on public.club_records (created_by);

alter table public.club_records enable row level security;
drop policy if exists cr_read on public.club_records;
create policy cr_read on public.club_records for select to authenticated using ((select auth.uid()) is not null);
drop policy if exists cr_coach_insert on public.club_records;
create policy cr_coach_insert on public.club_records for insert to authenticated with check (private.is_coach());
drop policy if exists cr_coach_update on public.club_records;
create policy cr_coach_update on public.club_records for update to authenticated using (private.is_coach()) with check (private.is_coach());
drop policy if exists cr_coach_delete on public.club_records;
create policy cr_coach_delete on public.club_records for delete to authenticated using (private.is_coach());

-- Update 23 (17 Oct): record levels, so one board covers Club, WA State, Australian and World records
alter table public.club_records add column if not exists level text not null default 'club' check (level in ('club','wa','aus','world'));
alter table public.club_records add column if not exists nation text check (nation is null or length(nation) <= 40);
create index if not exists club_records_level_idx on public.club_records (level, sex, category, lift, weight_kg desc, set_on);

-- Update 24 to 26 (17 Oct, applied through the connector): IWF classes from 1 Aug 2026, and the daily records sync
-- 24: category check now men 60 65 70 75 85 95 110 +110, women 49 53 57 61 69 77 86 +86; source, source_url; unique index on synced rows
-- 25: is_current, note; public.records_sync_apply(level, source, rows) (service_role only): marks the source's list current, keeps earlier rows as history, links lifters to athletes by name
-- 26: private.app_config 'records_sync_secret' (random); public.records_sync_check (service_role); private.records_sync_call(levels, dry) posts to the records-sync edge function;
--     public.records_sync_now() for coaches (Refresh button)
-- pg_cron job 'records-sync-daily' at 18:15 UTC (2:15 am Perth): select private.records_sync_call(null, false)
