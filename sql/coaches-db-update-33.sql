-- 33: Coach profiles.
-- profiles.role: 'coach' = Head Coach (Ant, full access, unchanged), 'staff' = Coach (read only), 'athlete'.
-- Coaches (staff) can read: every group program (Base, Competitive, FNDN, Free Trial and any future group plan type),
-- published only, never individual programs except their own; all groups; profiles (names); classes, bookings and drop-ins.
-- They cannot write anything beyond what an athlete can (their own logs, notes, bookings).
-- Not visible to coaches: coach notes to athletes they aren't grouped with, athlete notes, memberships, billing, waivers, agreements, other people's chats.
-- Only the Head Coach can change a role (private.guard_profile_update already resets role for everyone else).

create or replace function private.is_staff()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('coach', 'staff'));
$$;
revoke all on function private.is_staff() from public;
grant execute on function private.is_staff() to authenticated;

-- Group programs: published, attached to a plan that isn't Individual or archived
create or replace function private.staff_can_view_program(p uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select private.is_staff() and exists (
    select 1 from public.programs pr
    join public.program_plans pl on pl.id = pr.plan_id
    where pr.id = p and pr.status = 'published'
      and upper(pl.plan_type) <> 'INDIVIDUAL' and pl.status <> 'archived'
  );
$$;
revoke all on function private.staff_can_view_program(uuid) from public;
grant execute on function private.staff_can_view_program(uuid) to authenticated;

create or replace function private.can_view_program(p uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select private.is_coach() or private.staff_can_view_program(p) or exists (
    select 1 from public.programs pr
    join public.program_assignments a on a.program_id = pr.id
    where pr.id = p and pr.status = 'published'
      and (a.athlete_id = auth.uid() or (a.group_id is not null and private.in_group(a.group_id)))
  );
$$;

-- Classes and cancellations: coaches see the timetable even while bookings are in beta
create or replace function private.bookings_visible()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select private.bookings_live() or private.is_staff() or exists (
    select 1 from public.group_members gm join public.groups g on g.id = gm.group_id
    where gm.profile_id = auth.uid() and lower(trim(g.name)) = 'beta testers');
$$;

drop policy if exists staff_read on public.program_plans;
create policy staff_read on public.program_plans for select to authenticated
  using (private.is_staff() and upper(plan_type) <> 'INDIVIDUAL' and status <> 'archived');

drop policy if exists staff_read on public.groups;
create policy staff_read on public.groups for select to authenticated using (private.is_staff());

drop policy if exists staff_read on public.profiles;
create policy staff_read on public.profiles for select to authenticated using (private.is_staff());

drop policy if exists staff_read on public.class_bookings;
create policy staff_read on public.class_bookings for select to authenticated using (private.is_staff());

drop policy if exists staff_read on public.drop_ins;
create policy staff_read on public.drop_ins for select to authenticated using (private.is_staff());

-- Keep role values tidy
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('athlete', 'staff', 'coach'));
