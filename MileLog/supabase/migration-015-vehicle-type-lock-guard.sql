-- ============================================================================
-- MileLog Phase 17 round 18 migration: block changing a vehicle's type
--   (own vs. company) once it has any locked trip.
--   Every reimbursement/logbook computation (TripEditor.isOwnCarTrip,
--   Store.exportCSV, PDFReporter.ownCarCandidates/companyLogbookCandidates,
--   SettingsView.companyVehicles) determines own-car vs. company-car via a
--   LIVE lookup of the vehicle's current type — none of them snapshot it
--   per-trip. Editing a vehicle's type retroactively reclassified every
--   trip ever driven in it, INCLUDING already-locked, already-reported
--   ones — a complete bypass of trip_lock_guard's "once reported,
--   immutable" guarantee for the exact figure it exists to freeze, with
--   zero audit trail (round-18 adversarial review finding). The app itself
--   now blocks this in Store.updateVehicle and VehicleEditView's UI; this
--   closes the same gap at the database level, matching the existing
--   defense-in-depth pattern (trip_lock_guard/trip_lock_delete_guard) for
--   any access that bypasses the app entirely.
-- Idempotent: safe to re-run.
-- ============================================================================

create or replace function vehicle_type_lock_guard() returns trigger as $$
begin
  if new.vehicle_type is distinct from old.vehicle_type
     and exists (select 1 from trips t where t.vehicle_id = old.id and t.is_locked) then
    raise exception 'Vehicle type cannot be changed once it has locked trips';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists vehicles_type_lock on vehicles;
create trigger vehicles_type_lock before update on vehicles
  for each row execute function vehicle_type_lock_guard();
