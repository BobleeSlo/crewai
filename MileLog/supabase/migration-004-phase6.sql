-- ============================================================================
-- MileLog Phase 6 migration:
--   * Add commute_rate to user_settings (€/km for Home ↔ Work trips).
-- Idempotent: safe to re-run.
-- ============================================================================

alter table user_settings
  add column if not exists commute_rate numeric(5,3) default 0.180;
