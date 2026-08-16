-- ============================================================================
-- MileLog Phase 17 round 16 migration: RLS policies now verify that a
--   referenced foreign key actually belongs to the same account, not just
--   that the row itself is tagged with the caller's own user_id.
--   own_points (trip_points) already did this; own_trips/own_receipts/
--   own_audit_insert never checked that trips.vehicle_id/customer_id,
--   receipts.trip_id, or trip_audit_log.trip_id belonged to the caller's
--   own vehicles/trips — letting an authenticated user write a row of
--   their own referencing another account's vehicle/trip/customer by
--   guessed UUID (round-16 adversarial review finding). Exploitability was
--   already low (the SELECT-side policies still prevent ever reading back
--   another account's real data), but this closes the gap for consistency
--   with own_points' existing pattern.
-- Idempotent: safe to re-run.
-- ============================================================================

drop policy if exists own_trips on trips;
create policy own_trips on trips
  for all
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (select 1 from vehicles v where v.id = trips.vehicle_id and v.user_id = auth.uid())
    and (trips.customer_id is null
         or exists (select 1 from customers c where c.id = trips.customer_id and c.user_id = auth.uid()))
  );

drop policy if exists own_receipts on receipts;
create policy own_receipts on receipts
  for all
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and (receipts.trip_id is null
         or exists (select 1 from trips t where t.id = receipts.trip_id and t.user_id = auth.uid()))
  );

drop policy if exists own_audit_insert on trip_audit_log;
create policy own_audit_insert on trip_audit_log
  for insert
  with check (
    auth.uid() = user_id
    and exists (select 1 from trips t where t.id = trip_audit_log.trip_id and t.user_id = auth.uid())
  );
