-- ============================================================================
-- MileLog Phase 8a migration:
--   * Add energy_mode to user_settings so the GPS battery/accuracy preset
--     syncs with the rest of the user's preferences.
-- Idempotent: safe to re-run.
-- ============================================================================

alter table user_settings
  add column if not exists energy_mode text default 'balanced';

-- Allowed values mirror the Swift EnergyMode rawValue cases.
alter table user_settings drop constraint if exists user_settings_energy_mode_check;
alter table user_settings
  add constraint user_settings_energy_mode_check
  check (energy_mode in ('low_power', 'balanced', 'high_accuracy'));
