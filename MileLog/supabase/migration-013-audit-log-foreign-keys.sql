-- ============================================================================
-- MileLog Phase 17 round 14 migration: trip_audit_log had no foreign key
--   constraints on trip_id/user_id at all, unlike every other table in this
--   schema (trip_points, receipts, etc. all reference trips(id)/
--   auth.users(id) explicitly). RLS's own_audit/own_audit_insert policies
--   check only auth.uid() = user_id, never that trip_id actually belongs to
--   that user's own trip — a real referential-integrity gap in the one
--   table whose entire purpose is being a trustworthy, well-formed
--   tamper-evident trail (round-14 adversarial review finding).
-- Idempotent: safe to re-run (guards against the constraint already existing).
-- ============================================================================

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'trip_audit_log_trip_id_fkey'
  ) then
    alter table trip_audit_log
      add constraint trip_audit_log_trip_id_fkey
      foreign key (trip_id) references trips(id) on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'trip_audit_log_user_id_fkey'
  ) then
    alter table trip_audit_log
      add constraint trip_audit_log_user_id_fkey
      foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
end $$;
