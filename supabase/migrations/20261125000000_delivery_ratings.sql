-- Delivery orders (Grubhub, DoorDash, Uber Eats...): approved 2026-11-25 as "rating only, no territory".
-- The food photo can be taken anywhere. The rating shows in a place's overall, team and friends'
-- ratings, but the game runner leaves it out of area and place ownership.
alter table public.ratings add column delivery boolean not null default false;
