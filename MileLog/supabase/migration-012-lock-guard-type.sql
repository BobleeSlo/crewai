-- ============================================================================
-- MileLog Phase 17 round 12 migration: trip_lock_guard now also protects
--   trip_type. It already blocked started_at/odometer_*/distance_km/
--   vehicle_id/is_locked changes on a locked row, but never trip_type —
--   even though Trip.reimbursement() (client-side) pays a different rate,
--   or zero, per type. A locked, already-reported trip's Business/Commute/
--   Private classification could be silently flipped after the fact,
--   silently changing every future PDF/CSV export's reimbursement figure
--   for that trip with no re-confirmation (round-12 adversarial review
--   finding). trip_before_insert() (fires BEFORE this trigger, alphabetical
--   ordering) may still recompute reimbursement_amount_eur off the
--   attempted new trip_type first, but this trigger's exception aborts the
--   whole UPDATE statement atomically, so nothing from that recompute is
--   ever actually committed.
-- Idempotent: safe to re-run.
-- ============================================================================

create or replace function trip_lock_guard() returns trigger as $$
begin
  if old.is_locked then
    if new.started_at        is distinct from old.started_at
       or new.odometer_start_km is distinct from old.odometer_start_km
       or new.odometer_end_km   is distinct from old.odometer_end_km
       or new.distance_km       is distinct from old.distance_km
       or new.vehicle_id        is distinct from old.vehicle_id
       or new.trip_type         is distinct from old.trip_type
       or new.is_locked = false then
      raise exception 'Trip is locked; mileage/date/vehicle/type cannot be changed, and it cannot be unlocked';
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trips_lock on trips;
create trigger trips_lock before update on trips
  for each row execute function trip_lock_guard();
