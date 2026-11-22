-- Receipt review (D18, D19) and look-alike receipt flags (D17).
-- Pending ratings keep their receipt photo in the private "receipts" storage bucket
-- until a reviewer decides; photos are deleted 30 days after review (D20).

alter table public.ratings
  add column receipt_printed_at timestamptz,
  add column receipt_number text,
  -- The date printed on the receipt, when the app could read it.
  add column receipt_date date,
  -- Set when the phone uploaded the receipt photo for review.
  add column receipt_photo boolean not null default false,
  add column reviewed_at timestamptz,
  add column reviewed_by uuid,
  add column review_note text,
  add column photo_deleted_at timestamptz;

alter table public.ratings drop constraint ratings_pending_check;
alter table public.ratings add constraint ratings_pending_check
  check (pending <@ array['typedReceipt', 'noFoodPhoto', 'lookAlike']::text[]);

-- Another player's rating at the same place whose receipt looks like part of the same
-- order: printed within 10 minutes, or an order number within 3 on the same day (D17).
create table public.look_alikes (
  rating_id uuid not null references public.ratings (id) on delete cascade,
  matches uuid not null references public.ratings (id) on delete cascade,
  reason text not null,
  primary key (rating_id, matches)
);

create function public.find_look_alikes(
  rating uuid, player uuid, place text, printed timestamptz, number text, day date
) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  found integer := 0;
  n bigint := case when number ~ '^\d{1,15}$' then number::bigint end;
begin
  -- Order numbers often restart daily, so they only match receipts from the same day.
  day := coalesce((printed at time zone 'America/New_York')::date, day);
  insert into public.look_alikes (rating_id, matches, reason)
  select rating, r.id,
         case when printed is not null and r.receipt_printed_at is not null
                   and abs(extract(epoch from r.receipt_printed_at - printed)) <= 600
              then 'printed minutes apart' else 'order numbers in a row' end
    from public.ratings r
   where r.place_id = place and r.player_id <> player and r.id <> rating
     and (
       (printed is not null and r.receipt_printed_at is not null
        and abs(extract(epoch from r.receipt_printed_at - printed)) <= 600)
       or (n is not null and r.receipt_number ~ '^\d{1,15}$'
           and abs(r.receipt_number::bigint - n) <= 3
           and day is not null
           and coalesce((r.receipt_printed_at at time zone 'America/New_York')::date, r.receipt_date) = day)
     )
  on conflict do nothing;
  get diagnostics found = row_count;
  return found;
end $$;
revoke execute on function public.find_look_alikes(uuid, uuid, text, timestamptz, text, date) from public, anon, authenticated;

-- Players can't mark their own rating reviewed or photo-deleted.
create or replace function public.stamp_rating() returns trigger
language plpgsql as $$
declare
  place record;
begin
  new.rated_at := now();
  new.rejected := false;
  new.reviewed_at := null;
  new.reviewed_by := null;
  new.review_note := null;
  new.photo_deleted_at := null;
  new.pending := array(select distinct unnest(array_remove(new.pending, 'lookAlike')));
  -- Typed-in receipt details always mean the receipt needs a review (D18).
  if new.typed_business is not null or new.typed_date is not null then
    new.pending := array(select distinct unnest(new.pending || array['typedReceipt']));
  end if;
  select p.latitude, p.longitude into place from public.places p where p.id = new.place_id;
  if found then
    new.latitude := place.latitude;
    new.longitude := place.longitude;
  elsif exists (select 1 from public.places) then
    raise exception 'Unknown place.' using errcode = 'P0001';
  end if;
  new.counted_at := case when new.pending = '{}' then now() end;
  return new;
end $$;

-- After the row exists (look_alikes points at it), flag it if it looks like part of
-- another player's order. The rating waits for review instead of counting.
create function public.flag_look_alike() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.find_look_alikes(new.id, new.player_id, new.place_id, new.receipt_printed_at,
                             new.receipt_number, new.receipt_date) > 0 then
    update public.ratings
       set pending = array(select distinct unnest(pending || array['lookAlike'])), counted_at = null
     where id = new.id;
  end if;
  return new;
end $$;

create trigger ratings_flag_look_alike after insert on public.ratings
  for each row execute function public.flag_look_alike();

-- The phone marks a rating's receipt photo as uploaded (the only column it may change).
grant update (receipt_photo) on public.ratings to authenticated;
create policy "mark own receipt uploaded" on public.ratings
  for update to authenticated using (player_id = auth.uid()) with check (player_id = auth.uid());

-- Reviewers: people allowed to approve or reject pending ratings.
create table public.reviewers (
  player_id uuid primary key references public.players (id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.reviewers enable row level security;
alter table public.look_alikes enable row level security;
revoke all on public.reviewers, public.look_alikes from anon, authenticated;

create function public.is_reviewer() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.reviewers where player_id = auth.uid())
$$;

-- Everything a reviewer needs, oldest first.
create function public.review_queue()
returns table (
  id uuid, place_id text, verdict text, stars smallint, rated_at timestamptz, pending text[],
  typed_business text, typed_date date, receipt_printed_at timestamptz, receipt_number text,
  receipt_path text, look_alike_reasons text[]
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_reviewer() then
    raise exception 'Only reviewers can see the review queue.' using errcode = '42501';
  end if;
  return query
    select r.id, r.place_id, r.verdict, r.stars, r.rated_at, r.pending,
           r.typed_business, r.typed_date, r.receipt_printed_at, r.receipt_number,
           case when r.receipt_photo and r.photo_deleted_at is null
                then r.player_id::text || '/' || r.id::text || '.jpg' end,
           array(select l.reason from public.look_alikes l where l.rating_id = r.id)
      from public.ratings r
     where r.pending <> '{}' and not r.rejected and r.reviewed_at is null
       -- A missing photo waits for a revisit first; it needs review only after 30 days.
       and (r.pending <> array['noFoodPhoto']
            or (r.rated_at at time zone 'America/New_York')::date + 30
               < (now() at time zone 'America/New_York')::date)
     order by r.rated_at;
end $$;

-- Approve: the rating counts from now. Reject: it never counts.
create function public.review_rating(rating uuid, approve boolean, note text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_reviewer() then
    raise exception 'Only reviewers can review ratings.' using errcode = '42501';
  end if;
  update public.ratings
     set pending = case when approve then '{}' else pending end,
         rejected = not approve,
         counted_at = case when approve then now() else null end,
         reviewed_at = now(), reviewed_by = auth.uid(), review_note = note
   where id = rating;
  if not found then
    raise exception 'No such rating.' using errcode = 'P0002';
  end if;
end $$;

revoke execute on function public.review_queue(), public.review_rating(uuid, boolean, text) from public, anon;
grant execute on function public.review_queue(), public.review_rating(uuid, boolean, text), public.is_reviewer() to authenticated;

-- Private receipt photos: a player uploads only into their own folder; reviewers can read.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('receipts', 'receipts', false)
      on conflict (id) do nothing;
    execute $p$create policy "upload own receipts" on storage.objects for insert to authenticated
      with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
    execute $p$create policy "reviewers read receipts" on storage.objects for select to authenticated
      using (bucket_id = 'receipts' and public.is_reviewer())$p$;
  end if;
end $$;
