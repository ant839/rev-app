-- Update 31 (17 Oct 2026, applied through the connector): Ant removed the minimum term reminder.
-- The WA Fitness Code (clause 17) only requires notice before the initial term ends when that term is over 6 months; Rev's longest is 12 weeks.
update public.membership_plans
set agreement_body = regexp_replace(agreement_body, '([a-z])\. Before my minimum term ends, the Club will remind me in the Rev app so I can cancel without a fee if I choose\.\s*\n\n[a-z]\. If an athlete stops attending', '\1. If an athlete stops attending')
where agreement_body ilike '%remind me%';
select cron.unschedule('min-term-reminders') where exists (select 1 from cron.job where jobname = 'min-term-reminders');
