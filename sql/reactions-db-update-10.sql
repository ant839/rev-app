-- Update 10 (14 Oct 2026): more reactions. Forum: lifter, cry, devil. Chat: weightlifter, crying face, devil face.
-- Safe to run twice. Applied by Claude through the Supabase connector.
alter table public.post_reactions drop constraint if exists post_reactions_kind_check,
  add constraint post_reactions_kind_check check (kind = any (array['fire','strong','clap','lifter','cry','devil']));
alter table public.message_reactions drop constraint if exists message_reactions_emoji_check,
  add constraint message_reactions_emoji_check check (emoji = any (array['👍','❤️','😂','🔥','💪','👏','😮','🏋️','😭','😈']));
