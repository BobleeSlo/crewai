-- ============================================================================
-- MileLog — Supabase schema (company-car logbook + business mileage)
-- Run this in the Supabase SQL Editor (one block at a time, or all at once).
-- ============================================================================

-- ---------- TABLES ----------

create table if not exists vehicles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  license_plate text not null default '',
  vehicle_type text not null check (vehicle_type in ('own','company')),
  default_purpose text default 'business' check (default_purpose in ('business','private','commute')),
  current_odometer_km integer default 0,
  is_active boolean default true,
  created_at timestamptz default now()
);

create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  contact_person text,
  address text,
  city text,
  lat double precision,
  lng double precision,
  notes text,
  created_at timestamptz default now()
);

create table if not exists trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  vehicle_id uuid not null references vehicles(id),
  sequential_number integer,
  trip_type text not null default 'business' check (trip_type in ('business','private','commute')),
  customer_id uuid references customers(id),
  purpose text,
  contact_met text,
  started_at timestamptz not null,
  ended_at timestamptz,
  start_address text,
  start_lat double precision,
  start_lng double precision,
  end_address text,
  end_lat double precision,
  end_lng double precision,
  intermediate_stops jsonb default '[]'::jsonb,
  odometer_start_km integer,
  odometer_end_km integer,
  distance_km numeric(8,2),
  reimbursement_rate_eur numeric(5,3) default 0.430,
  reimbursement_amount_eur numeric(10,2),
  notes text,
  is_locked boolean default false,
  reviewed_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists trip_points (
  id bigserial primary key,
  trip_id uuid not null references trips(id) on delete cascade,
  recorded_at timestamptz not null,
  lat double precision not null,
  lng double precision not null,
  speed_kmh real,
  accuracy_m real
);

create table if not exists receipts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  trip_id uuid references trips(id) on delete cascade,
  receipt_type text not null check (receipt_type in ('fuel','parking','toll','other')),
  amount_eur numeric(10,2),
  vendor text,
  photo_url text,
  receipt_date date,
  notes text,
  created_at timestamptz default now()
);

create table if not exists trip_audit_log (
  id bigserial primary key,
  trip_id uuid not null references trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  changed_at timestamptz default now(),
  field_name text,
  old_value text,
  new_value text
);

create index if not exists trips_user_started_idx on trips(user_id, started_at);
create index if not exists trip_points_trip_idx on trip_points(trip_id);
create index if not exists receipts_trip_idx on receipts(trip_id);

-- ---------- TRIGGERS ----------

create or replace function touch_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end;
$$ language plpgsql;

drop trigger if exists trips_touch on trips;
create trigger trips_touch before update on trips
  for each row execute function touch_updated_at();

-- Per-user sequential number + distance + reimbursement on insert.
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

-- Runs on UPDATE too (not just INSERT) so editing an unlocked trip's
-- distance/type doesn't leave reimbursement_amount_eur stale.
drop trigger if exists trips_bi on trips;
create trigger trips_bi before insert or update on trips
  for each row execute function trip_before_insert();

-- Keep the vehicle's odometer in sync with the latest trip.
create or replace function trip_after_write() returns trigger as $$
begin
  if new.odometer_end_km is not null then
    update vehicles set current_odometer_km = new.odometer_end_km
      where id = new.vehicle_id and current_odometer_km < new.odometer_end_km;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trips_aw on trips;
create trigger trips_aw after insert or update on trips
  for each row execute function trip_after_write();

-- Once a trip is locked, mileage / date / vehicle / type become immutable,
-- and is_locked itself is a one-way ratchet (the app never sets it back to
-- false — locking is permanent by design, so an UPDATE that flips it back
-- is by definition unauthorized, not a legitimate app flow). trip_type is
-- included because it directly determines the reimbursement figure the
-- lock exists to freeze (round-12 adversarial review finding — it was
-- omitted even though distance/vehicle/date already had this guard).
create or replace function trip_lock_guard() returns trigger as $$
begin
  if old.is_locked then
    if new.started_at        is distinct from old.started_at
       or new.odometer_start_km is distinct from old.odometer_start_km
       or new.odometer_end_km   is distinct from old.odometer_end_km
       or new.distance_km       is distinct from old.distance_km
       or new.vehicle_id        is distinct from old.vehicle_id
       or new.trip_type         is distinct from old.trip_type
       or new.is_locked = false then
      raise exception 'Trip is locked; mileage/date/vehicle/type cannot be changed, and it cannot be unlocked';
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trips_lock on trips;
create trigger trips_lock before update on trips
  for each row execute function trip_lock_guard();

-- The UPDATE guard above had no DELETE equivalent — a locked trip (the
-- exact record the locking feature exists to make tamper-evident for a
-- tax audit) could be deleted outright via any direct API/SQL access that
-- bypasses the app's own Swift-level check.
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

-- The trip-level lock guards above only protect the trips table itself —
-- but every reimbursement/logbook computation determines own-car vs.
-- company-car via a LIVE lookup of the vehicle's own type, not a per-trip
-- snapshot. Changing a vehicle's type after the fact would retroactively
-- reclassify every trip ever driven in it, including already-locked ones,
-- completely bypassing trip_lock_guard's "once reported, immutable"
-- guarantee for the exact figure it exists to freeze, via a table that
-- guard was never watching (round-18 adversarial review finding). Frozen
-- the same way: once any trip referencing this vehicle is locked, its type
-- can no longer change.
create or replace function vehicle_type_lock_guard() returns trigger as $$
begin
  if new.vehicle_type is distinct from old.vehicle_type
     and exists (select 1 from trips t where t.vehicle_id = old.id and t.is_locked) then
    raise exception 'Vehicle type cannot be changed once it has locked trips';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists vehicles_type_lock on vehicles;
create trigger vehicles_type_lock before update on vehicles
  for each row execute function vehicle_type_lock_guard();

-- ---------- ROW-LEVEL SECURITY ----------

alter table vehicles       enable row level security;
alter table customers      enable row level security;
alter table trips          enable row level security;
alter table trip_points    enable row level security;
alter table receipts       enable row level security;
alter table trip_audit_log enable row level security;

drop policy if exists own_vehicles on vehicles;
create policy own_vehicles on vehicles
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists own_customers on customers;
create policy own_customers on customers
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- with check also verifies that vehicle_id/customer_id actually belong to
-- the same account, not just that the trip row itself is tagged with the
-- caller's own user_id — own_points already did this for trip_points, but
-- own_trips/own_receipts/own_audit* didn't, letting an authenticated user
-- write a row of their OWN that references another account's vehicle/
-- trip/customer by guessed id (round-16 adversarial review finding). Only
-- with check needs this (not using): user_id already correctly scopes
-- which rows are visible/updatable at all.
drop policy if exists own_trips on trips;
create policy own_trips on trips
  for all
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (select 1 from vehicles v where v.id = trips.vehicle_id and v.user_id = auth.uid())
    and (trips.customer_id is null
         or exists (select 1 from customers c where c.id = trips.customer_id and c.user_id = auth.uid()))
  );

drop policy if exists own_receipts on receipts;
create policy own_receipts on receipts
  for all
  using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and (receipts.trip_id is null
         or exists (select 1 from trips t where t.id = receipts.trip_id and t.user_id = auth.uid()))
  );

drop policy if exists own_points on trip_points;
create policy own_points on trip_points
  for all
  using (exists (select 1 from trips t where t.id = trip_points.trip_id and t.user_id = auth.uid()))
  with check (exists (select 1 from trips t where t.id = trip_points.trip_id and t.user_id = auth.uid()));

drop policy if exists own_audit on trip_audit_log;
create policy own_audit on trip_audit_log
  for select using (auth.uid() = user_id);

-- INSERT was missing entirely (the table only ever had a SELECT policy),
-- so Store.recordAuditDiff's insert was silently rejected by RLS for every
-- edit to a locked trip — the compliance audit trail this app's own UI
-- promises ("recorded in the audit log") never actually persisted anything.
drop policy if exists own_audit_insert on trip_audit_log;
create policy own_audit_insert on trip_audit_log
  for insert
  with check (
    auth.uid() = user_id
    and exists (select 1 from trips t where t.id = trip_audit_log.trip_id and t.user_id = auth.uid())
  );
