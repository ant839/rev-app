-- Coach app update 7 (3 Oct 2026): coach notifications on the phone.
-- Coach-app devices get pings for chat messages, new athlete sign-ups, forum comments and new
-- forum posts, and tapping one opens the coach app (coach.html) on the right screen. Each
-- device can switch each kind on or off. Athlete-app devices work exactly as before.
-- Safe to run twice. Applied 3 Oct 2026 ~15:45 by Claude through the Supabase connector and tested in
-- rolled-back transactions (comment, muted comment, sign-up and chat message each queued the right push).

-- which app a device subscribed from, and that device's on/off choices
alter table public.push_subscriptions add column if not exists app text not null default 'athlete';
alter table public.push_subscriptions add column if not exists prefs jsonb not null default '{}'::jsonb;
do $$ begin
  alter table public.push_subscriptions add constraint push_subscriptions_app_chk check (app in ('athlete','coach'));
exception when duplicate_object then null; end $$;

-- One place that sends pushes. url = where athlete-app devices go (null = don't send to them),
-- coach_url = where coach-app devices go (null = don't send to them). kind is the on/off switch
-- name (messages, signups, comments, posts); a device that hasn't chosen counts as on.
create or replace function private.push_out(recipients uuid[], ttl text, msg text, url text, coach_url text, tag text, kind text)
returns void language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare subs jsonb; secret text;
begin
  if recipients is null then return; end if;
  if length(msg) > 160 then msg := left(msg, 157) || '...'; end if;
  select value into secret from private.app_config where key = 'push_hook_secret';
  if url is not null then
    select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into subs
      from push_subscriptions s where s.profile_id = any(recipients) and s.app <> 'coach';
    if subs is not null then
      perform net.http_post(url := 'https://kaehtivwphtwoiaeszui.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object('Content-Type','application/json','x-hook-secret', secret),
        body := jsonb_build_object('subs', subs, 'title', ttl, 'body', msg, 'url', url, 'tag', tag));
    end if;
  end if;
  if coach_url is not null then
    select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) into subs
      from push_subscriptions s join profiles p on p.id = s.profile_id and p.role = 'coach'
      where s.profile_id = any(recipients) and s.app = 'coach'
        and (kind is null or coalesce((s.prefs->>kind)::boolean, true));
    if subs is not null then
      perform net.http_post(url := 'https://kaehtivwphtwoiaeszui.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object('Content-Type','application/json','x-hook-secret', secret),
        body := jsonb_build_object('subs', subs, 'title', ttl, 'body', msg, 'url', coach_url, 'tag', tag));
    end if;
  end if;
exception when others then
  raise warning 'push failed: %', sqlerrm;   -- never block the thing that triggered it
end; $$;

-- the existing helper (used for new forum posts) now goes through push_out:
-- athlete-app devices open the app as before, coach-app devices open the same thing in coach.html
create or replace function private.send_push(recipients uuid[], ttl text, msg text, url text, tag text)
returns void language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  perform private.push_out(recipients, ttl, msg, url,
    replace(url, '/rev-app/#', '/rev-app/coach.html#'), tag,
    case when tag like 'post-%' then 'posts' else null end);
end; $$;

-- chat messages: same recipients and wording as before
create or replace function private.notify_new_message()
returns trigger language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare c record; who uuid[]; ttl text; msg text;
begin
  select cv.*, g.name as group_name into c from conversations cv left join groups g on g.id = cv.group_id where cv.id = new.conversation_id;
  select array_agg(distinct pid) into who from (
    select gm.profile_id as pid from group_members gm where c.group_id is not null and gm.group_id = c.group_id
    union select p.id from profiles p where c.group_id is not null and p.role = 'coach'
    union select cm.profile_id from conversation_members cm where cm.conversation_id = c.id
  ) r where pid is distinct from new.author_id;
  if who is null then return new; end if;
  ttl := case when c.kind = 'direct' then coalesce(new.author_name, 'New message')
              else coalesce(c.title, c.group_name, 'Group chat') end;
  msg := case when c.kind = 'direct' then new.body
              else split_part(coalesce(new.author_name,'Someone'),' ',1) || ': ' || new.body end;
  perform private.push_out(who, ttl, msg,
    'https://ant839.github.io/rev-app/#chat/' || c.id,
    'https://ant839.github.io/rev-app/coach.html#chat/' || c.id,
    'chat-' || c.id, 'messages');
  return new;
exception when others then
  raise warning 'push notify failed: %', sqlerrm;
  return new;
end; $$;

-- new athlete signed up: coaches only
create or replace function private.notify_new_athlete()
returns trigger language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare who uuid[];
begin
  if new.role = 'coach' then return new; end if;
  select array_agg(id) into who from profiles where role = 'coach' and id <> new.id;
  perform private.push_out(who, 'New athlete signed up',
    coalesce(nullif(new.full_name,''), new.email, 'Someone') || ' just joined. Put them on a program.',
    null, 'https://ant839.github.io/rev-app/coach.html#athlete/' || new.id, 'signup-' || new.id, 'signups');
  return new;
exception when others then
  raise warning 'signup push failed: %', sqlerrm;
  return new;
end; $$;
create or replace trigger profiles_push after insert on public.profiles for each row execute function private.notify_new_athlete();

-- forum comments: coaches only (not their own comments)
create or replace function private.notify_new_comment()
returns trigger language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare who uuid[]; t text;
begin
  select title into t from posts where id = new.post_id;
  select array_agg(id) into who from profiles where role = 'coach' and id is distinct from new.author_id;
  perform private.push_out(who,
    coalesce(new.author_name, 'An athlete') || case when new.parent_id is null then ' commented' else ' replied' end || ' on ' || coalesce('"' || t || '"', 'a post'),
    new.body, null, 'https://ant839.github.io/rev-app/coach.html#post/' || new.post_id, 'comment-' || new.post_id, 'comments');
  return new;
exception when others then
  raise warning 'comment push failed: %', sqlerrm;
  return new;
end; $$;
create or replace trigger post_comments_push after insert on public.post_comments for each row execute function private.notify_new_comment();

-- "Send a test" button in the coach app's Notifications settings
create or replace function public.coach_test_push() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if not private.is_coach() then raise exception 'Coaches only'; end if;
  select count(*) into n from push_subscriptions where profile_id = auth.uid() and app = 'coach';
  perform private.push_out(array[auth.uid()], 'Rev Coach', 'Notifications are working on this phone.',
    null, 'https://ant839.github.io/rev-app/coach.html#home', 'test', null);
  return jsonb_build_object('ok', true, 'devices', n);
end; $$;
grant execute on function public.coach_test_push() to authenticated;

-- wording: comments from athletes are signed "Athlete", never "Member", when a name is missing
create or replace function private.stamp_comment_author()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare p record;
begin
  select full_name, role into p from public.profiles where id = new.author_id;
  new.author_name := case when p.role = 'coach' then 'Coach ' || split_part(coalesce(p.full_name,'Coach'),' ',1)
                          else coalesce(nullif(p.full_name,''),'Athlete') end;
  new.author_role := p.role;
  return new;
end; $$;
