# MileLog — business trip & company-car logbook (iOS)

A SwiftUI iPhone app for logging business trips. Record a drive, label it as
**business / commute / private**, pick which **vehicle** (your own car or the
company car), and export a monthly mileage report (CSV) for reimbursement or a
company-car logbook. Data syncs to your own Supabase project.

This folder is **self-contained** — you can copy it into its own Git repository
at any time.

---

## What's here

```
MileLog/
├── MileLog/                      ← Swift source (drop into an Xcode app target)
│   ├── MileLogApp.swift          ← app entry + auth gate
│   ├── Models.swift              ← Vehicle, Trip, enums
│   ├── Store.swift               ← local persistence (JSON) + cloud sync
│   ├── LocationManager.swift     ← GPS distance tracking
│   ├── SupabaseConfig.swift      ← reads URL + anon key from Info.plist
│   ├── SupabaseService.swift     ← auth + CRUD against Supabase
│   ├── SupabaseDTO.swift         ← Swift ⇄ Postgres mapping
│   └── Views/                    ← Auth, Record, Trips, Vehicles, Settings
├── supabase/
│   └── schema.sql                ← tables + triggers + Row-Level Security
└── README.md
```

---

## Setup — step by step

### 1) Supabase project (one-time, ~5 min)

1. Sign in at [supabase.com](https://supabase.com) → **New project** (region:
   *Central EU – Frankfurt*).
2. Open **SQL Editor → New query**, paste the *entire* `supabase/schema.sql`,
   click **Run**. You should see "Success. No rows returned."
3. Verify Row-Level Security is on (this is critical, the publishable key alone
   is not protection):
   - **Database → Tables** → for `vehicles`, `trips`, `customers`, `receipts`,
     `trip_points`, `trip_audit_log`, the "RLS enabled" toggle must be **green**.
4. **Authentication → Providers** → leave *Email* enabled. To skip the
   confirmation email while you test, toggle **"Confirm email"** off (you can
   turn it back on later).
5. **Settings → API** → copy:
   - **Project URL**  → `https://xxxx.supabase.co`
   - **Publishable (anon) key** → `sb_publishable_...`

### 2) Xcode project (one-time, ~10 min)

You need **Xcode 15+** and an Apple ID. A paid Apple Developer account ($99/yr)
is only required to publish to the App Store; you can install on your own iPhone
for free with any Apple ID.

1. Xcode → *File ▸ New ▸ Project ▸ iOS ▸ App*.
   - Product Name: `MileLog`, Interface: **SwiftUI**, Language: **Swift**.
   - Minimum deployment target: **iOS 16.0** or later.
2. Delete the auto-generated `ContentView.swift` and `MileLogApp.swift`, then
   drag every file from this folder's `MileLog/` (the inner one) into the Xcode
   project navigator → *Copy items if needed*, *Create groups*.
3. Add the **Supabase Swift SDK**:
   *File ▸ Add Package Dependencies…* → URL: `https://github.com/supabase/supabase-swift`
   → choose **Up to Next Major Version**, add the `Supabase` library to your app target.
4. Add **location permission strings** (target → *Info* tab → "+" a new key):
   - `Privacy - Location When In Use Usage Description` →
     *"MileLog measures the distance of your trips."*
   - `Privacy - Location Always and When In Use Usage Description` →
     *"MileLog records trips in the background so you don't have to."*
     *(only needed for Phase 3, leave for now)*
5. **Add your Supabase credentials** (target → *Info* tab, "+" two new keys, type
   *String*):
   - `SUPABASE_URL` → `https://xxxx.supabase.co` *(your Project URL)*
   - `SUPABASE_ANON_KEY` → `sb_publishable_...` *(your publishable key)*
6. Build & run on the Simulator or your iPhone. Create an account on the sign-in
   screen, then log a trip from the *Record* tab.

> **Never commit your real `SUPABASE_*` values.** Anyone with the publishable
> key + a known email/password can read that user's data; the secret
> `service_role` key would bypass RLS entirely. Keep both out of git.

---

## Current status

**Phase 1 — Local-first MVP** ✅
- One-tap Start/Stop trip recording (GPS distance) and manual distance entry
- Classify trips, manage vehicles, monthly grouping with business-km totals
- Editable per-km reimbursement rate + CSV export

**Phase 2 — Supabase sync** ✅
- Email/password auth (sign up + sign in)
- Trips and vehicles synced to your Supabase project
- Row-Level Security keeps every row scoped to its owner
- Push-on-save + pull-on-launch; local JSON acts as offline cache

**Phase 3a — Foundations for auto-detection** ✅
- Per-vehicle Bluetooth pairing: tap **"Pair with current Bluetooth
  connection"** in Vehicles → Edit, while your phone is connected to the car
  audio. The car's BT name + UID are stored against that vehicle.
- Per-vehicle default trip type (business / commute / private).
- **Settings → Home & Work** addresses (auto-geocoded to lat/lng), plus an
  auto-detect toggle and a stationary-timeout stepper.
- Settings synced to a new `user_settings` table (one row per user, RLS-scoped).
- Run `supabase/migration-002-phase3a.sql` in the SQL Editor once.

**Phase 4a — Monthly PDF logbook** ✅
- New **Settings → Monthly PDF logbook** section with month + year pickers and a
  ShareLink that exports an A4 portrait PDF for the chosen month.
- Layout: title + monthly totals (trips, total km, business km, reimbursement €),
  followed by a per-trip table (date, vehicle, type, from/to, km, €). Multi-page
  with zebra stripes; trips ordered chronologically.
- Implemented with `UIGraphicsPDFRenderer` — no third-party PDF dependency.

**Phase 4b — Trip locking + audit log** ✅
- Trips automatically lock after `UserSettings.lockAfterDays` (default 7 days).
- Locked trips are read-only for mileage / date / vehicle in the editor;
  purpose / customer / notes stay editable, and every change is pushed to
  `trip_audit_log` for the compliance audit trail.
- Trips list row shows a small lock badge on locked entries.
- Settings → Compliance & locking: stepper + "Apply locks now" button.

**Phase 4c — GPS track storage** ✅
- `TripDetector` records each GPS update during an auto-detected trip into
  `ActiveTripState.points`; on trip end the full polyline is pushed to the
  Supabase `trip_points` table.
- `TripEditor` pulls points lazily and renders them on an embedded MapKit
  polyline (`TripMapView`) with start/end annotations.

**Phase 4d — Receipts** ✅
- Inline "Receipts" section in the trip editor with a `PhotosPicker` for
  attaching fuel / parking / toll / other receipts.
- Photo is uploaded as JPEG to the Supabase Storage `receipts` bucket under
  `<user_id>/<receipt_id>.jpg`, with a matching row in the `receipts` table.
- Receipts list shows thumbnails (downloaded on-demand from Storage) with type,
  amount and date.
- Storage bucket + per-user RLS policies are created by
  `supabase/migration-003-phase4.sql`.

**Phase 3b — Automatic trip detection** ✅
- `TripDetector` wakes the app on significant location changes, identifies the
  car via the connected Bluetooth audio device, and starts a trip with the
  matching vehicle.
- Active GPS while a trip runs (kept alive by `UIBackgroundModes = location`).
- Trip ends on **Bluetooth disconnect** or after the configured stationary
  timeout (default 5 min), whichever fires first.
- `TripClassifier` picks a default trip type using ordered rules: commute
  pattern (Home ↔ Work on a weekday at a plausible hour), company-car =
  business, weekend/evening own-car = private, otherwise the vehicle's
  configured default.
- Local notification with **Business / Commute / Private** quick actions on
  trip end — tap an action to update the trip's classification in-place.
- **Settings → Detection log** — last 100 events (significant-location wakes,
  trip start/end, BT route changes, errors) for debugging on real drives.
- Active trip persisted to disk so a force-quit doesn't lose the in-progress
  recording.

**Required Xcode setup for Phase 3b**

1. Target → **Signing & Capabilities** → **+ Capability → Background Modes**
   → check **Location updates**.
2. Target → **Info** tab → confirm the existing location strings, and the app
   will request "Always" authorization on first toggle. Make sure your
   "Always" usage description clearly says the app monitors trips in the
   background.

**Phase 4 — Compliance & reporting** *(planned)*
- GPS track storage (`trip_points`) for auto-detected trips
- Trip locking after N days + edit audit (`trip_audit_log`)
- Monthly / quarterly PDF logbook export, optionally signed
- Fuel / parking / toll receipts (`receipts`)

---

## Notes

- **Reimbursement rate** defaults to `0.43 €/km` as a placeholder. Confirm the
  current official rate for your situation (it changes over time and by country)
  and update it in **Settings**.
- **Logbook compliance**: you selected an EU country-specific logbook. Before
  relying on the export for tax or audit purposes, verify the exact required
  fields with your accountant or the relevant tax authority.
- The Swift sources were authored in a Linux container and **not compiled
  there** — do a first build in Xcode and fix any minor issues
  (deployment-target tweaks, missing imports if you reorganize files, etc.).
