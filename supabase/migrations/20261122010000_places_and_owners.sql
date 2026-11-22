-- Places, and who owns what. Places come from the same Overture catalogue as the app,
-- with each place's area (an H3 cell of about 0.7 km², resolution 8). Owners are
-- written by the game runner (server/runner), which replays ratings and check-ins
-- through the rules engine.

create table public.places (
  id text primary key,
  latitude double precision not null,
  longitude double precision not null,
  area text not null
);
create index places_area on public.places (area);

-- When a rating started counting (no pending reasons). The runner uses this time,
-- so a rating that clears review later counts from then, not from when it was made.
alter table public.ratings add column counted_at timestamptz;
update public.ratings set counted_at = rated_at where pending = '{}' and counted_at is null;

create or replace function public.stamp_rating() returns trigger
language plpgsql as $$
declare
  place record;
begin
  new.rated_at := now();
  new.rejected := false;
  -- Typed-in receipt details always mean the receipt needs a review (D18).
  if new.typed_business is not null or new.typed_date is not null then
    new.pending := array(select distinct unnest(new.pending || array['typedReceipt']));
  end if;
  new.counted_at := case when new.pending = '{}' then now() end;
  -- The place's position comes from the server's catalogue, not from the phone.
  select p.latitude, p.longitude into place from public.places p where p.id = new.place_id;
  if found then
    new.latitude := place.latitude;
    new.longitude := place.longitude;
  elsif exists (select 1 from public.places) then
    raise exception 'Unknown place.' using errcode = 'P0001';
  end if;
  return new;
end $$;

create function public.stamp_counted() returns trigger
language plpgsql as $$
begin
  if old.pending <> '{}' and new.pending = '{}' and new.counted_at is null then
    new.counted_at := now();
  end if;
  return new;
end $$;

create trigger ratings_counted before update on public.ratings
  for each row execute function public.stamp_counted();

create table public.area_owners (
  area text primary key,
  team text not null check (team in ('team1', 'team2', 'team3')),
  -- The hexagon's corners as [[lat, lon], ...], so the app can draw it without H3.
  boundary jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.place_owners (
  place_id text primary key,
  team text not null check (team in ('team1', 'team2', 'team3')),
  area text not null,
  updated_at timestamptz not null default now()
);

create table public.game_runs (
  ran_at timestamptz primary key default now(),
  ratings integer not null,
  check_ins integer not null,
  skipped jsonb not null default '{}'
);

alter table public.places enable row level security;
alter table public.area_owners enable row level security;
alter table public.place_owners enable row level security;
alter table public.game_runs enable row level security;

-- Everyone signed in can see places and the map's owners; only the server writes them.
create policy "read places" on public.places for select to authenticated using (true);
create policy "read area owners" on public.area_owners for select to authenticated using (true);
create policy "read place owners" on public.place_owners for select to authenticated using (true);
revoke insert, update, delete on public.places, public.area_owners, public.place_owners, public.game_runs
  from authenticated, anon;
revoke all on public.places, public.area_owners, public.place_owners, public.game_runs from anon;

-- The runner swaps in a whole new ownership result at once, so the map never sees
-- empty tables or a mix of two runs, and a failed run keeps the last good result.
create function public.replace_owners(areas jsonb, places jsonb, run jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.area_owners where true;
  insert into public.area_owners (area, team, boundary)
    select a->>'area', a->>'team', a->'boundary' from jsonb_array_elements(areas) a;
  delete from public.place_owners where true;
  insert into public.place_owners (place_id, team, area)
    select p->>'place_id', p->>'team', p->>'area' from jsonb_array_elements(places) p;
  insert into public.game_runs (ratings, check_ins, skipped)
    values ((run->>'ratings')::int, (run->>'check_ins')::int, coalesce(run->'skipped', '{}'));
end $$;

revoke execute on function public.replace_owners(jsonb, jsonb, jsonb) from public, anon, authenticated;
