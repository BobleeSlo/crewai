-- ============================================================================
-- MileLog Phase 17 migration: "potni nalog" (Slovenian travel-order logbook)
--   report fields.
--   * vehicles: seat_count, vehicle_type_description
--   * user_settings: company_name, company_address, company_location,
--     driver_name, trip_beneficiary, trip_area
-- Idempotent: safe to re-run.
-- ============================================================================

alter table vehicles
  add column if not exists seat_count integer default 5,
  add column if not exists vehicle_type_description text default 'OSEBNI AVTOMOBIL';

alter table user_settings
  add column if not exists company_name text default '',
  add column if not exists company_address text default '',
  add column if not exists company_location text default '',
  add column if not exists driver_name text default '',
  add column if not exists trip_beneficiary text default '',
  add column if not exists trip_area text default 'Območje RS';
