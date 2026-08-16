-- ============================================================================
-- MileLog Phase 3a migration:
--   * extend vehicles with Bluetooth pairing + default trip type
--   * add user_settings (per-user preferences: rate, home, work, auto-detect)
-- Idempotent: safe to re-run.
-- ============================================================================

-- Vehicles: Bluetooth pairing + default trip type ----------------------------

alter table vehicles
  add column if not exists bluetooth_name text default '',
  add column if not exists bluetooth_uid  text default '',
  add column if not exists default_trip_type text default 'business';

-- Enforce the same domain as trips.trip_type. If the constraint already
-- exists, the create will fail — we drop first so the migration stays safe.
alter table vehicles drop constraint if exists vehicles_default_trip_type_check;
alter table vehicles
  add constraint vehicles_default_trip_type_check
  check (default_trip_type in ('business','private','commute'));

-- Per-user settings ----------------------------------------------------------

create table if not exists user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reimbursement_rate numeric(5,3) default 0.430,
  home_address text default '',
  home_lat double precision,
  home_lng double precision,
  work_address text default '',
  work_lat double precision,
  work_lng double precision,
  auto_detect_enabled boolean default false,
  stationary_timeout_minutes int default 5,
  updated_at timestamptz default now()
);

create or replace function user_settings_touch_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end;
$$ language plpgsql;

drop trigger if exists user_settings_touch on user_settings;
create trigger user_settings_touch before update on user_settings
  for each row execute function user_settings_touch_updated_at();

alter table user_settings enable row level security;

drop policy if exists own_settings on user_settings;
create policy own_settings on user_settings for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
