-- Digital receipts: a receipt shared into the app as a PDF, saved email or screenshot.
-- Easier to fake than paper, so the rating waits for review (it shows in the review queue
-- like a typed-in receipt).
alter table public.ratings drop constraint ratings_pending_check;
alter table public.ratings add constraint ratings_pending_check
  check (pending <@ array['typedReceipt', 'noFoodPhoto', 'lookAlike', 'digitalReceipt']::text[]);
