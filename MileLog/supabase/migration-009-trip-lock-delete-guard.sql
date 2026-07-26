-- ============================================================================
-- MileLog Phase 17 migration: block deleting a locked trip at the database
--   level, mirroring the existing trip_lock_guard BEFORE UPDATE trigger.
--   A locked trip is the exact record the locking feature exists to make
--   tamper-evident for a tax audit — without this, any direct API/SQL
--   access bypassing the app's own Swift-level check could delete one
--   outright with no trace.
-- Idempotent: safe to re-run.
-- ============================================================================

create or replace function trip_lock_delete_guard() returns trigger as $$
begin
  if old.is_locked then
    raise exception 'Trip is locked; it cannot be deleted';
  end if;
  return old;
end;
$$ language plpgsql;

drop trigger if exists trips_lock_delete on trips;
create trigger trips_lock_delete before delete on trips
  for each row execute function trip_lock_delete_guard();
