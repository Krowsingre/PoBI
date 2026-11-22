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

reset role;
insert into places values ('real-place', 40.5, -74.5, '882a10000ffffff');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into ratings (id, place_id, latitude, longitude, verdict, stars)
  values (gen_random_uuid(), 'real-place', 0, 0, 'plateIt', 3);
insert into expect select 'place position comes from the catalogue',
  (select latitude = 40.5 and longitude = -74.5 from ratings where place_id = 'real-place');
insert into expect select 'a rating with nothing pending counts now',
  (select counted_at is not null from ratings where place_id = 'real-place');
do $$ begin
  insert into ratings (id, place_id, latitude, longitude, verdict, stars)
    values (gen_random_uuid(), 'made-up', 40, -74, 'plateIt', 1);
  insert into expect values ('unknown places are refused', false);
exception when raise_exception then
  insert into expect values ('unknown places are refused', true);
end $$;
insert into expect select 'a missing photo cleared by a check-in counts from then',
  (select counted_at > rated_at - interval '1 second' from ratings where place_id = 'p1');
do $$ begin
  perform replace_owners('[]', '[]', '{"ratings":0,"check_ins":0}');
  insert into expect values ('players cannot run the owner swap', false);
exception when insufficient_privilege then
  insert into expect values ('players cannot run the owner swap', true);
end $$;
do $$ begin
  insert into area_owners values ('x', 'team1', '[]');
  insert into expect values ('players cannot set owners', false);
exception when insufficient_privilege then
  insert into expect values ('players cannot set owners', true);
end $$;

-- Look-alike receipts (D17): player 2 rates real-place with a receipt printed 4 minutes after player 1's.
reset role;
insert into players (id, team) values ('22222222-2222-2222-2222-222222222222', 'team3');
insert into places values ('p5', 40.6, -74.6, '882a10000ffffff');
update ratings set receipt_printed_at = '2026-11-20 12:00-05', receipt_number = '1041' where place_id = 'real-place';
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into ratings (id, place_id, latitude, longitude, verdict, stars, receipt_printed_at, receipt_number)
  values ('33333333-3333-3333-3333-333333333333', 'real-place', 0, 0, 'plateIt', 3, '2026-11-20 12:04-05', '1043');
insert into expect select 'a look-alike receipt waits for review',
  (select pending = '{lookAlike}' and counted_at is null from ratings where id = '33333333-3333-3333-3333-333333333333');
insert into ratings (id, place_id, latitude, longitude, verdict, stars, receipt_printed_at, receipt_number, pending)
  values (gen_random_uuid(), 'p5', 40, -74, 'plateIt', 1, '2026-11-20 18:00-05', '77', '{lookAlike}');
insert into expect select 'players cannot set the look-alike flag themselves',
  (select pending = '{}' from ratings where place_id = 'p5');

do $$ begin
  perform review_queue();
  insert into expect values ('only reviewers see the queue', false);
exception when insufficient_privilege then
  insert into expect values ('only reviewers see the queue', true);
end $$;
update ratings set receipt_photo = true where id = '33333333-3333-3333-3333-333333333333';
insert into expect select 'a player can mark their receipt photo uploaded',
  (select receipt_photo from ratings where id = '33333333-3333-3333-3333-333333333333');

reset role;
insert into reviewers values ('11111111-1111-1111-1111-111111111111');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into expect select 'the reviewer sees the flagged rating and why',
  (select look_alike_reasons = '{printed minutes apart}' and receipt_path like '2222%' from review_queue()
    where id = '33333333-3333-3333-3333-333333333333');
insert into expect select 'a missing photo is not in the queue during its 30 days',
  (select count(*) = 0 from review_queue() where pending = '{noFoodPhoto}');
select review_rating('33333333-3333-3333-3333-333333333333', true, 'same family, separate orders');
insert into expect select 'approving makes it count',
  (select count(*) = 0 from review_queue() where id = '33333333-3333-3333-3333-333333333333');

reset role;
select replace_owners('[{"area":"A","team":"team2","boundary":[[1,2]]}]',
                      '[{"place_id":"real-place","team":"team2","area":"A"}]', '{"ratings":1,"check_ins":0}');
select replace_owners('[{"area":"B","team":"team3","boundary":[[1,2]]}]', '[]', '{"ratings":1,"check_ins":0}');
insert into expect select 'owner swap replaces the whole result',
  (select count(*) = 1 and bool_and(area = 'B') from area_owners) and (select count(*) = 0 from place_owners);

select name, ok from expect;
do $$ begin
  if exists (select 1 from expect where not ok) then raise exception 'A rules check failed'; end if;
end $$;
