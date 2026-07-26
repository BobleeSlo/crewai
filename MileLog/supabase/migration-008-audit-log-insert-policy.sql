-- ============================================================================
-- MileLog Phase 17 migration: trip_audit_log was missing an INSERT policy.
--   The table only ever had a SELECT policy (`own_audit`), so
--   Store.recordAuditDiff's insert was silently rejected by RLS for every
--   edit to a locked trip's purpose/customer/notes/type — the compliance
--   audit trail the app's own UI promises ("recorded in the audit log")
--   never actually persisted anything.
-- Idempotent: safe to re-run.
-- ============================================================================

drop policy if exists own_audit_insert on trip_audit_log;
create policy own_audit_insert on trip_audit_log
  for insert with check (auth.uid() = user_id);
