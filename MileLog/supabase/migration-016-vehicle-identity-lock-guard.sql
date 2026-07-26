-- ============================================================================
-- MileLog Phase 17 round 19 migration: extend vehicle_type_lock_guard
--   (migration-015) to also freeze name/license_plate/vehicle_type_description/
--   seat_count once a vehicle has any locked trip, not just vehicle_type.
--
--   All four are printed straight from the live Vehicle row into the
--   own-car PDF/CSV or the potni nalog header at Generate-tap time, never
--   snapshotted per-trip — re-registering or renaming a car after some of
--   its trips are locked would silently change what a re-generated
--   historical Potni Nalog prints for those already-reported trips
--   (round-19 adversarial review finding: the third instance of the
--   "trip lock protects the trip row but not a mutable dependency it
--   renders through" pattern, following trip_type in round 12 and
--   vehicle_type in round 18). default_trip_type (defaultTripType) and
--   Bluetooth pairing are exempt: neither is ever printed on a report or
--   affects an already-classified trip.
--
--   Also backfills seat_count/vehicle_type_description onto the vehicles
--   table in schema.sql itself (they previously existed only via
--   migration-007, never folded back into the base snapshot) so a fresh
--   install has the columns this trigger references.
-- Idempotent: safe to re-run.
-- ============================================================================

alter table vehicles
  add column if not exists seat_count integer default 5,
  add column if not exists vehicle_type_description text default 'OSEBNI AVTOMOBIL';

create or replace function vehicle_type_lock_guard() returns trigger as $$
begin
  if (new.vehicle_type              is distinct from old.vehicle_type
      or new.name                   is distinct from old.name
      or new.license_plate          is distinct from old.license_plate
      or new.vehicle_type_description is distinct from old.vehicle_type_description
      or new.seat_count             is distinct from old.seat_count)
     and exists (select 1 from trips t where t.vehicle_id = old.id and t.is_locked) then
    raise exception 'Vehicle identity/type cannot be changed once it has locked trips';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists vehicles_type_lock on vehicles;
create trigger vehicles_type_lock before update on vehicles
  for each row execute function vehicle_type_lock_guard();
