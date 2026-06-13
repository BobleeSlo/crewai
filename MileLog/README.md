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

**Phase 3 — Automatic trip detection** *(planned)*
- Significant-location + visit monitoring and `CMMotionActivityManager` driving
  detection to start/stop trips automatically and surface a "Classify your trip"
  notification on arrival. Requires the *Location updates* background mode and
  *Always* location permission.

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
