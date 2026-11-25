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
insert into places values ('p6', 40.7, -74.7, '882a10000ffffff');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into ratings (id, place_id, latitude, longitude, verdict, stars, receipt_number, receipt_date)
  values (gen_random_uuid(), 'p6', 0, 0, 'plateIt', 2, '500', '2026-10-01');
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into ratings (id, place_id, latitude, longitude, verdict, stars, receipt_number, receipt_date)
  values (gen_random_uuid(), 'p6', 0, 0, 'plateIt', 2, '501', '2026-11-20');
insert into expect select 'close order numbers on different days are not flagged',
  (select pending = '{}' from ratings where place_id = 'p6' and player_id = auth.uid());
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

-- App Attest: rows that come through the edge function carry its secret header.
insert into places values ('p7', 40.8, -74.8, '882a10000ffffff'), ('p8', 40.9, -74.9, '882a10000ffffff');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into ratings (id, place_id, latitude, longitude, verdict, stars, attested)
  values (gen_random_uuid(), 'p7', 0, 0, 'plateIt', 1, true);
insert into expect select 'players cannot mark their own rows attested',
  (select not attested from ratings where place_id = 'p7');
do $$ begin
  perform 1 from app_keys;
  insert into expect values ('players cannot read app keys', false);
exception when insufficient_privilege then
  insert into expect values ('players cannot read app keys', true);
end $$;
reset role;
select set_config('request.headers', json_build_object('x-pobi-attest', (select secret from attest_settings))::text, false);
update attest_settings set require_attest = true;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into ratings (id, place_id, latitude, longitude, verdict, stars)
  values (gen_random_uuid(), 'p8', 0, 0, 'plateIt', 1);
insert into expect select 'rows with the function''s header are attested',
  (select attested from ratings where place_id = 'p8');
select set_config('request.headers', '{"x-pobi-attest":"guess"}', false);
do $$ begin
  insert into check_ins (id, place_id, latitude, longitude, accuracy) values (gen_random_uuid(), 'p8', 40.9, -74.9, 10);
  insert into expect values ('when required, unattested rows are refused', false);
exception when sqlstate 'PT426' then
  insert into expect values ('when required, unattested rows are refused', true);
end $$;
reset role;
update attest_settings set require_attest = false;
select set_config('request.headers', '', false);

-- Friends and shared ratings.
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select set_nickname('  Embre  ');
insert into expect select 'nickname is trimmed and saved', (select nickname = 'Embre' and length(friend_code) = 8 from my_profile());
update players set team = 'team1';
insert into expect select 'a nickname doesn''t reopen the team pick', (select team = 'team2' from players);
create temp table codes as select (select friend_code from my_profile()) as mine;
grant all on codes to public;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into expect select 'strangers can''t see each other''s ratings',
  (select count(*) = 0 from friend_ratings('11111111-1111-1111-1111-111111111111'));
insert into expect select 'adding by code sends a request', (select add_friend(lower((select mine from codes)))) = 'requested';
insert into expect select 'a request alone shares nothing',
  (select count(*) = 0 from friend_ratings('11111111-1111-1111-1111-111111111111'));
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into expect select 'the other player sees the request', (select status = 'incoming' from friends());
select answer_friend('22222222-2222-2222-2222-222222222222', true);
insert into expect select 'accepting makes you friends', (select status = 'friend' from friends());
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into expect select 'friends see each other''s counted ratings',
  (select count(*) > 0 from friend_ratings('11111111-1111-1111-1111-111111111111'));
insert into expect select 'a place shows its overall, team and friends'' ratings',
  (select (r -> 'overall' ->> 'plate')::int >= 1 and (r -> 'friends' ->> 'plate')::int >= 1
          and jsonb_array_length(r -> 'friend_ratings') >= 1 and r -> 'friend_ratings' -> 0 ->> 'nickname' = 'Embre'
   from (select place_ratings('real-place') as r) x);
do $$ begin
  perform add_friend('NOPE0000');
  insert into expect values ('unknown codes are refused', false);
exception when raise_exception then
  insert into expect values ('unknown codes are refused', true);
end $$;
select remove_friend('11111111-1111-1111-1111-111111111111');
insert into expect select 'removing a friend stops sharing',
  (select count(*) = 0 from friend_ratings('11111111-1111-1111-1111-111111111111'));
reset role;

-- Digital receipts wait for review.
insert into places values ('p9', 41.0, -75.0, '882a10000ffffff');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into ratings (id, place_id, latitude, longitude, verdict, stars, pending, receipt_photo)
  values ('99999999-9999-9999-9999-999999999999', 'p9', 0, 0, 'breakIt', 2, '{digitalReceipt}', true);
insert into expect select 'a digital receipt rating is pending',
  (select pending = '{digitalReceipt}' and counted_at is null from ratings where place_id = 'p9');
insert into expect select 'a digital receipt is in the review queue',
  (select count(*) = 1 from review_queue() where id = '99999999-9999-9999-9999-999999999999');
reset role;

-- Delivery ratings: stored, shown in the place's ratings (the runner leaves them out of territory).
insert into places values ('p10', 41.1, -75.1, '882a10000ffffff');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into ratings (id, place_id, latitude, longitude, verdict, stars, delivery)
  values (gen_random_uuid(), 'p10', 0, 0, 'plateIt', 3, true);
insert into expect select 'a delivery rating is saved and counts as a rating',
  (select delivery and counted_at is not null from ratings where place_id = 'p10');
insert into expect select 'a delivery rating shows in the place''s overall',
  (select (place_ratings('p10') -> 'overall' ->> 'plate')::int = 1);
reset role;

select name, ok from expect;
do $$ begin
  if exists (select 1 from expect where not ok) then raise exception 'A rules check failed'; end if;
end $$;
