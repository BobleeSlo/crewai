-- ============================================================================
-- MileLog Phase 4 migration (4b + 4c + 4d):
--   * Trip locking metadata (locked_at)
--   * Per-user lock-after-days preference
--   * Storage bucket for receipt photos + RLS policies
-- Idempotent: safe to re-run.
-- ============================================================================

-- 4b: trip locking metadata --------------------------------------------------

alter table trips
  add column if not exists locked_at timestamptz;

alter table user_settings
  add column if not exists lock_after_days int default 7;

-- The trip_audit_log table + own_audit policy already exist from the initial
-- schema, so no further migration is needed for auditing.

-- 4d: receipts bucket --------------------------------------------------------
-- Buckets must usually be created via the Supabase dashboard; this is the
-- equivalent SQL for completeness. Run it manually OR create the bucket from
-- Dashboard → Storage → New bucket → "receipts" (private).

insert into storage.buckets (id, name, public)
  values ('receipts', 'receipts', false)
  on conflict (id) do nothing;

-- RLS policies for the receipts bucket — each user can only access objects
-- in their own folder (the upload path is "<user_id>/<file>").

drop policy if exists "Users can read own receipts"      on storage.objects;
drop policy if exists "Users can insert own receipts"    on storage.objects;
drop policy if exists "Users can update own receipts"    on storage.objects;
drop policy if exists "Users can delete own receipts"    on storage.objects;

create policy "Users can read own receipts"
  on storage.objects for select
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Users can insert own receipts"
  on storage.objects for insert
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Users can update own receipts"
  on storage.objects for update
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Users can delete own receipts"
  on storage.objects for delete
  using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
