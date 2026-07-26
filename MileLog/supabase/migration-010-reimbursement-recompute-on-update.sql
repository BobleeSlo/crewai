-- ============================================================================
-- MileLog Phase 17 round 9 migration: recompute reimbursement_amount_eur (and
--   the odometer-derived distance_km) on UPDATE, not just INSERT.
--   trip_before_insert() previously only ran BEFORE INSERT, so editing an
--   unlocked trip's distance or type after its first sync left
--   reimbursement_amount_eur stale in the database — the app itself never
--   notices (it always recomputes client-side from the current trip/settings),
--   but the stored column silently drifts from what the app displays. Locked
--   trips are unaffected: trip_lock_guard already forbids changing
--   distance/odometer/type-relevant fields once is_locked is true.
-- Idempotent: safe to re-run.
-- ============================================================================

create or replace function trip_before_insert() returns trigger as $$
begin
  if new.sequential_number is null then
    select coalesce(max(sequential_number), 0) + 1 into new.sequential_number
      from trips where user_id = new.user_id;
  end if;
  if new.odometer_start_km is not null and new.odometer_end_km is not null then
    new.distance_km = new.odometer_end_km - new.odometer_start_km;
  end if;
  if new.distance_km is not null and new.trip_type = 'business' then
    new.reimbursement_amount_eur =
      round(new.distance_km * coalesce(new.reimbursement_rate_eur, 0.430), 2);
  else
    new.reimbursement_amount_eur = null;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trips_bi on trips;
create trigger trips_bi before insert or update on trips
  for each row execute function trip_before_insert();
