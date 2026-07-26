-- ============================================================================
-- MileLog Phase 17 round 11 migration: trip_lock_guard never protected
--   is_locked itself from being flipped back to false. It only blocked
--   changes to started_at/odometer_*/distance_km/vehicle_id while
--   old.is_locked was true — an UPDATE that left those fields untouched but
--   set is_locked = false (e.g. from a stale client-side view re-saving an
--   outdated snapshot, or any direct API/SQL access) was silently accepted,
--   permanently un-locking the row. The app itself never sets is_locked
--   back to false anywhere (Store.applyAutomaticLocks only ever sets it to
--   true) — locking is a one-way ratchet by design, so this closes the gap
--   at the one layer that's supposed to make it tamper-evident regardless
--   of client bugs or direct API access.
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
       or new.is_locked = false then
      raise exception 'Trip is locked; mileage/date/vehicle cannot be changed, and it cannot be unlocked';
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trips_lock on trips;
create trigger trips_lock before update on trips
  for each row execute function trip_lock_guard();
