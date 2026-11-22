-- App Attest: ratings and check-ins should come from the real app on a real iPhone.
--
-- The phone proves this with Apple's App Attest. The `attest` edge function checks
-- the proof, then passes the rating or check-in on to the database with a secret
-- header that only the function knows. Rows that arrive that way are marked
-- `attested`. While `require_attest` is off, other rows are still accepted (and
-- marked not attested), so a mistake in the check can't stop the game.

create table public.attest_settings (
  id boolean primary key default true check (id),
  require_attest boolean not null default false,
  -- Shared only between the database and the edge function (which reads it with the service key).
  secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into public.attest_settings default values;

-- Keys the phones made with App Attest, one per install and account.
create table public.app_keys (
  key_id text primary key,
  player_id uuid not null references public.players (id) on delete cascade,
  public_key text not null,
  sign_count bigint not null default 0,
  environment text not null check (environment in ('production', 'development')),
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index app_keys_player on public.app_keys (player_id);

alter table public.attest_settings enable row level security;
alter table public.app_keys enable row level security;
revoke all on public.attest_settings, public.app_keys from anon, authenticated;

alter table public.ratings add column attested boolean not null default false;
alter table public.check_ins add column attested boolean not null default false;

-- True when the request came through the edge function after a valid App Attest assertion.
create function public.attested_request() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select secret from public.attest_settings)
      = (nullif(current_setting('request.headers', true), '')::json ->> 'x-pobi-attest'),
    false)
$$;
revoke execute on function public.attested_request() from public, anon, authenticated;

create function public.stamp_attested() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.attested := public.attested_request();
  if not new.attested and (select require_attest from public.attest_settings) then
    -- PT426 makes PostgREST answer 426 Upgrade Required. Not P0001, so the app keeps it and retries.
    raise exception 'Update Plate or Break It to keep playing.' using errcode = 'PT426';
  end if;
  return new;
end
$$;

create trigger ratings_attested before insert on public.ratings
  for each row execute function public.stamp_attested();
create trigger check_ins_attested before insert on public.check_ins
  for each row execute function public.stamp_attested();

-- A player may read back their own receipt photos. Storage needs this to confirm an upload
-- (and to tell a retry that the photo is already there).
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    execute $p$create policy "read own receipts" on storage.objects for select to authenticated
      using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  end if;
end $$;
