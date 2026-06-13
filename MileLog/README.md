# MileLog — business trip & company-car logbook (iOS)

A SwiftUI iPhone app for logging business trips. Record a drive, label it as
**business / commute / private**, pick which **vehicle** (your own car or the
company car), and export a monthly mileage report (CSV) for reimbursement or a
company-car logbook.

This folder is **self-contained** — you can copy it into its own Git repository
at any time.

---

## What's here

```
MileLog/
├── MileLog/                 ← Swift source (drop these into an Xcode app target)
│   ├── MileLogApp.swift     ← app entry point
│   ├── Models.swift         ← Vehicle, Trip, enums
│   ├── Store.swift          ← local persistence (JSON) + CSV export
│   ├── LocationManager.swift← GPS distance tracking
│   └── Views/               ← all screens (Record, Trips, Vehicles, Settings)
├── supabase/
│   └── schema.sql           ← cloud backend schema (run later, see below)
└── README.md
```

## Current status — MVP (Phase 1)

The MVP is **local-first and dependency-free**: it compiles and runs with **no
external packages**. Data is stored on the device as JSON.

✅ Record a trip with one Start/Stop button (GPS measures distance)
✅ Classify each trip: business / commute / private, customer, purpose, notes
✅ Manage vehicles (own car / company car)
✅ Trips grouped by month, with per-month business-km totals
✅ Editable per-km reimbursement rate
✅ Export all trips as CSV (share / email)

> Distance can also be typed in manually on each trip (useful in the Simulator,
> which has no real GPS, or for odometer-style entry).

---

## How to build & run it (on a Mac)

You need **Xcode 15+** and, to run on your own iPhone, a free Apple ID (a paid
Apple Developer account, €99/yr, is only required to publish to the App Store).

1. **Create the project**: Xcode → *File ▸ New ▸ Project… ▸ iOS ▸ App*.
   - Product Name: `MileLog`
   - Interface: **SwiftUI**, Language: **Swift**
   - Set the minimum deployment target to **iOS 16.0** or later.
2. **Add the source files**: delete the auto-generated `ContentView.swift` and
   `MileLogApp.swift`, then drag everything from this folder's `MileLog/` (the
   inner one) into the Xcode project navigator → *Copy items if needed*, *Create
   groups*.
3. **Add the location permission strings** (required, or GPS silently fails).
   Select the project → your target → **Info** tab → add these keys:
   - `Privacy - Location When In Use Usage Description` →
     *"MileLog measures the distance of your trips."*
   - `Privacy - Location Always and When In Use Usage Description` →
     *"MileLog records trips in the background so you don't have to."*
     *(only needed once you enable background auto-detection — Phase 3)*
4. **Run**: pick your iPhone (or a Simulator) and press ▶. On a real device,
   allow location access when prompted.

---

## Roadmap

**Phase 2 — Cloud sync (Supabase)**
- Create a Supabase project (region: Central EU / Frankfurt).
- Run `supabase/schema.sql` in the Supabase SQL Editor.
- Add the [`supabase-swift`](https://github.com/supabase/supabase-swift) package
  via *File ▸ Add Package Dependencies…*
- Add a `SupabaseConfig.swift` with your **Project URL** + **anon key**
  (Settings ▸ API in the dashboard). The anon key is safe to embed — Row-Level
  Security restricts every row to its owner.
- Sign in with email or *Sign in with Apple*, then mirror `Store` reads/writes
  to the `trips` / `vehicles` / `customers` tables.

**Phase 3 — Automatic trip detection**
- Use Core Location *significant-location-change* + *visit* monitoring and
  `CMMotionActivityManager` (driving detection) to start/stop trips on their own,
  then send a "Classify your trip" notification on arrival.
- Requires the *Location updates* background mode + the *Always* permission.

**Phase 4 — Compliance & reporting**
- Save the GPS track (`trip_points`) as proof for auto-detected trips.
- Lock trips after N days (`is_locked`) and record edits in `trip_audit_log`.
- PDF logbook export (per month / per quarter), optionally with a signature/hash.
- Attach fuel / parking / toll receipts (`receipts`).

---

## Notes

- **Reimbursement rate**: the default is set to `0.43` €/km as a placeholder.
  Confirm the current official rate for your situation (it changes over time and
  by country) and update it in **Settings**.
- **Logbook rules**: you selected an EU country-specific logbook. Before relying
  on exports for tax/audit purposes, verify the exact required fields with your
  accountant or the relevant tax authority.
- I could not compile this in the build environment it was generated in, so do a
  first build in Xcode and fix any minor issues (e.g. deployment-target tweaks).
