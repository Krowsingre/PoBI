-- Friends and shared ratings.
--
-- Players pick a nickname and get a short friend code. Adding a friend by code sends a
-- request; once the other player accepts (or adds back), each can see the other's
-- ratings. Everyone can see a place's overall rating and their own team's, as totals only.
-- Only ratings that count (not pending, not rejected) are included anywhere.

alter table public.players add column nickname text check (char_length(nickname) between 1 and 24);
alter table public.players add column friend_code text unique;

create function public.new_friend_code() returns text
language sql volatile as $$
  -- 8 characters without look-alikes (no 0/O, 1/I/L).
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
  from generate_series(1, 8)
$$;

create function public.stamp_friend_code() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.friend_code := public.new_friend_code();
  return new;
end
$$;
create trigger players_friend_code before insert on public.players
  for each row execute function public.stamp_friend_code();
update public.players set friend_code = public.new_friend_code() where friend_code is null;
alter table public.players alter column friend_code set not null;

create table public.friend_requests (
  from_player uuid not null references public.players (id) on delete cascade,
  to_player uuid not null references public.players (id) on delete cascade,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  primary key (from_player, to_player),
  check (from_player <> to_player)
);
alter table public.friend_requests enable row level security;
revoke all on public.friend_requests from anon, authenticated;

-- True when the two players are friends (an accepted request either way).
create function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friend_requests
    where accepted_at is not null
      and ((from_player = a and to_player = b) or (from_player = b and to_player = a)))
$$;

-- Ratings that count toward anything.
create function public.counted_ratings() returns setof public.ratings
language sql stable security definer set search_path = '' as $$
  select * from public.ratings where counted_at is not null and not rejected
$$;

create function public.my_profile() returns table (nickname text, friend_code text)
language sql stable security definer set search_path = '' as $$
  select nickname, friend_code from public.players where id = auth.uid()
$$;

create function public.set_nickname(name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if char_length(btrim(name)) not between 1 and 24 then
    raise exception 'Pick a nickname of 1 to 24 characters.';
  end if;
  update public.players set nickname = btrim(name) where id = auth.uid();
end
$$;

-- Adds a friend by code. If they already asked you, this accepts. Returns what happened.
create function public.add_friend(code text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  them uuid;
begin
  select id into them from public.players where friend_code = upper(btrim(code));
  if them is null then raise exception 'No player has that friend code.'; end if;
  if them = me then raise exception 'That''s your own friend code.'; end if;
  if public.are_friends(me, them) then return 'already'; end if;
  update public.friend_requests set accepted_at = now()
    where from_player = them and to_player = me and accepted_at is null;
  if found then return 'accepted'; end if;
  insert into public.friend_requests (from_player, to_player) values (me, them)
    on conflict do nothing;
  return 'requested';
end
$$;

create function public.answer_friend(player uuid, accept boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if accept then
    update public.friend_requests set accepted_at = now()
      where from_player = player and to_player = auth.uid() and accepted_at is null;
  else
    delete from public.friend_requests where from_player = player and to_player = auth.uid();
  end if;
end
$$;

-- Removes a friend, or cancels a request you sent.
create function public.remove_friend(player uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.friend_requests
  where (from_player = auth.uid() and to_player = player) or (from_player = player and to_player = auth.uid())
$$;

-- Your friends and open requests. status: friend, incoming (they asked you), outgoing (you asked them).
create function public.friends() returns table (id uuid, nickname text, team text, status text, ratings bigint)
language sql stable security definer set search_path = '' as $$
  select p.id, p.nickname, p.team,
         case when r.accepted_at is not null then 'friend'
              when r.to_player = auth.uid() then 'incoming' else 'outgoing' end,
         case when r.accepted_at is not null
              then (select count(*) from public.counted_ratings() c where c.player_id = p.id) end
  from public.friend_requests r
  join public.players p on p.id = case when r.from_player = auth.uid() then r.to_player else r.from_player end
  where auth.uid() in (r.from_player, r.to_player)
  order by 4, p.nickname
$$;

-- A friend's counted ratings (only if you're friends).
create function public.friend_ratings(friend uuid)
returns table (place_id text, verdict text, stars smallint, rated_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select place_id, verdict, stars, rated_at from public.counted_ratings()
  where player_id = friend and public.are_friends(auth.uid(), friend)
  order by rated_at desc
$$;

-- Everything the place page shows about other players' ratings.
-- Score: Plate It counts +stars, Break It -stars; the average runs from -3 to +3.
create function public.place_ratings(place text) returns jsonb
language sql stable security definer set search_path = '' as $$
  with me as (select id, team from public.players where id = auth.uid()),
  rated as (
    select r.*, p.team, p.nickname,
           (r.player_id <> (select id from me) and public.are_friends((select id from me), r.player_id)) as is_friend
    from public.counted_ratings() r join public.players p on p.id = r.player_id
    where r.place_id = place
  )
  select jsonb_build_object(
    'overall', (select jsonb_build_object(
        'plate', count(*) filter (where verdict = 'plateIt'),
        'break', count(*) filter (where verdict = 'breakIt'),
        'score', round(avg(case when verdict = 'plateIt' then stars else -stars end), 1)) from rated),
    'team', (select jsonb_build_object(
        'plate', count(*) filter (where verdict = 'plateIt'),
        'break', count(*) filter (where verdict = 'breakIt'),
        'score', round(avg(case when verdict = 'plateIt' then stars else -stars end), 1))
      from rated where team = (select team from me)),
    'friends', (select jsonb_build_object(
        'plate', count(*) filter (where verdict = 'plateIt'),
        'break', count(*) filter (where verdict = 'breakIt'),
        'score', round(avg(case when verdict = 'plateIt' then stars else -stars end), 1))
      from rated where is_friend),
    'friend_ratings', coalesce((select jsonb_agg(jsonb_build_object(
        'nickname', coalesce(nickname, 'Friend'), 'team', team,
        'verdict', verdict, 'stars', stars, 'rated_at', rated_at) order by rated_at desc)
      from rated where is_friend), '[]'::jsonb))
$$;

revoke execute on function public.new_friend_code(), public.are_friends(uuid, uuid), public.counted_ratings()
  from public, anon, authenticated;
revoke execute on function public.my_profile(), public.set_nickname(text), public.add_friend(text),
  public.answer_friend(uuid, boolean), public.remove_friend(uuid), public.friends(),
  public.friend_ratings(uuid), public.place_ratings(text) from public, anon;
grant execute on function public.my_profile(), public.set_nickname(text), public.add_friend(text),
  public.answer_friend(uuid, boolean), public.remove_friend(uuid), public.friends(),
  public.friend_ratings(uuid), public.place_ratings(text) to authenticated;
