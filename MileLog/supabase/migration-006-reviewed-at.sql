-- ============================================================================
-- MileLog Phase 17 migration: Trip.reviewedAt
--   Marks a trip as human-reviewed (classified via the quick-classify
--   notification, edited in the trip detail screen, or manually recorded)
--   so TripDetector's merge/reclaim logic can refuse to ever resurrect a
--   reviewed trip as in-progress again. Without this column, cloud sync
--   silently dropped the flag on every relaunch, defeating the whole
--   mechanism the moment a signed-in device round-tripped through Supabase.
-- Idempotent: safe to re-run.
-- ============================================================================

alter table trips
  add column if not exists reviewed_at timestamptz;
