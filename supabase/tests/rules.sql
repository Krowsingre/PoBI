-- Checks the rules the database enforces. Any failed check stops the run.
\set ON_ERROR_STOP 1
insert into auth.users values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

create temp table expect (name text, ok boolean);

insert into players (id) values (auth.uid());
update players set team = 'team2';
update players set team = 'team3';
insert into expect select 'team is picked once', (select team from players) = 'team2';

do $$ begin
  insert into check_ins (id, place_id, latitude, longitude, accuracy) values (gen_random_uuid(), 'p1', 40.0003, -74, 10);
  insert into expect values ('check-in needs a rating', false);
exception when others then
  insert into expect values ('check-in needs a rating', true);
end $$;

insert into ratings (id, place_id, latitude, longitude, verdict, stars, pending, rated_at)
  values (gen_random_uuid(), 'p1', 40, -74, 'plateIt', 2, '{noFoodPhoto}', '2020-01-01');
insert into expect select 'rating time comes from the server', (select rated_at > now() - interval '1 minute' from ratings);

do $$ begin
  update ratings set pending = '{}';
  insert into expect values ('ratings cannot be edited', false);
exception when insufficient_privilege then
  insert into expect values ('ratings cannot be edited', true);
end $$;

do $$ begin
  insert into check_ins (id, place_id, latitude, longitude, accuracy) values (gen_random_uuid(), 'p1', 40.01, -74, 10);
  insert into expect values ('check-in must be within 80 m', false);
exception when raise_exception then
  insert into expect values ('check-in must be within 80 m', true);
end $$;
do $$ begin
  insert into check_ins (id, place_id, latitude, longitude, accuracy) values (gen_random_uuid(), 'p1', 40, -74, 500);
  insert into expect values ('check-in needs a usable fix', false);
exception when raise_exception then
  insert into expect values ('check-in needs a usable fix', true);
end $$;
insert into check_ins (id, place_id, latitude, longitude, accuracy, checked_at) values (gen_random_uuid(), 'p1', 40.0005, -74.0003, 20, '2020-01-01');
insert into expect select 'check-in time comes from the server', (select checked_at > now() - interval '1 minute' from check_ins);
insert into expect select 'a check-in clears a missing food photo', (select pending = '{}' from ratings);

do $$ begin
  insert into check_ins (id, place_id, latitude, longitude, accuracy) values (gen_random_uuid(), 'p1', 40.0003, -74, 10);
  insert into expect values ('one check-in a day', false);
exception when unique_violation then
  insert into expect values ('one check-in a day', true);
end $$;

insert into ratings (id, place_id, latitude, longitude, verdict, stars, typed_business, typed_date)
  values (gen_random_uuid(), 'p4', 40, -74, 'plateIt', 1, 'Some Diner', current_date);
insert into expect select 'typed receipts are always pending', (select pending = '{typedReceipt}' from ratings where place_id = 'p4');

set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into expect select 'players cannot see others'' ratings', (select count(*) = 0 from ratings);
do $$ begin
  insert into ratings (id, player_id, place_id, latitude, longitude, verdict, stars)
    values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'p2', 40, -74, 'plateIt', 1);
  insert into expect values ('players cannot rate as someone else', false);
exception when insufficient_privilege then
  insert into expect values ('players cannot rate as someone else', true);
end $$;

select name, ok from expect;
do $$ begin
  if exists (select 1 from expect where not ok) then raise exception 'A rules check failed'; end if;
end $$;
