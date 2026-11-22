-- Plate or Break It: players, ratings and check-ins.
-- Clients write through row-level security. Anything that decides the game
-- (when a check-in happened, whether a rating counts) is set by the database,
-- not trusted from the phone.

create table public.players (
  id uuid primary key references auth.users (id) on delete cascade,
  team text check (team in ('team1', 'team2', 'team3')),
  created_at timestamptz not null default now()
);

-- One original rating per player per place.
create table public.ratings (
  id uuid primary key,
  player_id uuid not null default auth.uid() references public.players (id) on delete cascade,
  place_id text not null,
  latitude double precision not null,
  longitude double precision not null,
  verdict text not null check (verdict in ('plateIt', 'breakIt')),
  stars smallint not null check (stars between 1 and 3),
  rated_at timestamptz not null default now(),
  storefront_photo boolean not null default false,
  -- Why the rating doesn't count yet (D18, D19). Empty means it counts.
  pending text[] not null default '{}'
    check (pending <@ array['typedReceipt', 'noFoodPhoto']::text[]),
  -- Set by review only: a rejected rating never counts.
  rejected boolean not null default false,
  typed_business text,
  typed_date date,
  unique (player_id, place_id)
);

create index ratings_place on public.ratings (place_id);
create index ratings_rated_at on public.ratings (rated_at);

create table public.check_ins (
  id uuid primary key,
  player_id uuid not null default auth.uid() references public.players (id) on delete cascade,
  place_id text not null,
  checked_at timestamptz not null default now(),
  -- The game day in New Jersey time, set by the database.
  game_day date not null,
  unique (player_id, place_id, game_day)
);

create index check_ins_place on public.check_ins (place_id, checked_at);

-- The server's clock decides when things happened; a phone can't backdate them.
create function public.stamp_rating() returns trigger
language plpgsql as $$
begin
  new.rated_at := now();
  new.rejected := false;
  return new;
end $$;

create trigger ratings_stamp before insert on public.ratings
  for each row execute function public.stamp_rating();

create function public.stamp_check_in() returns trigger
language plpgsql as $$
begin
  new.checked_at := now();
  new.game_day := (now() at time zone 'America/New_York')::date;
  if not exists (
    select 1 from public.ratings r
    where r.player_id = new.player_id and r.place_id = new.place_id and not r.rejected
  ) then
    raise exception 'Rate this place before checking in.' using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger check_ins_stamp before insert on public.check_ins
  for each row execute function public.stamp_check_in();

-- A check-in within 30 days of the rating makes up for a missing food photo (D19).
-- Runs as the table owner, because players can't update their own ratings.
create function public.clear_missing_photo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.ratings r
     set pending = array_remove(r.pending, 'noFoodPhoto')
   where r.player_id = new.player_id
     and r.place_id = new.place_id
     and 'noFoodPhoto' = any (r.pending)
     and new.game_day <= (r.rated_at at time zone 'America/New_York')::date + 30;
  return new;
end $$;

create trigger check_ins_clear_missing_photo after insert on public.check_ins
  for each row execute function public.clear_missing_photo();

-- Row-level security: players read and add their own rows only.
alter table public.players enable row level security;
alter table public.ratings enable row level security;
alter table public.check_ins enable row level security;

create policy "read own player" on public.players
  for select to authenticated using (id = auth.uid());
create policy "create own player" on public.players
  for insert to authenticated with check (id = auth.uid());
create policy "pick own team once" on public.players
  for update to authenticated using (id = auth.uid() and team is null) with check (id = auth.uid());

create policy "read own ratings" on public.ratings
  for select to authenticated using (player_id = auth.uid());
create policy "add own ratings" on public.ratings
  for insert to authenticated with check (player_id = auth.uid());

create policy "read own check-ins" on public.check_ins
  for select to authenticated using (player_id = auth.uid());
create policy "add own check-ins" on public.check_ins
  for insert to authenticated with check (player_id = auth.uid());

-- Players pick a team once; ids and timestamps stay fixed.
revoke update on public.players from authenticated;
grant update (team) on public.players to authenticated;
-- Ratings and check-ins can't be edited or deleted from the app.
revoke update, delete on public.ratings from authenticated, anon;
revoke update, delete on public.check_ins from authenticated, anon;
revoke all on public.players, public.ratings, public.check_ins from anon;
