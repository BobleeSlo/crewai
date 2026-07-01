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

**Phase 13 — Vehicle-switch detection + full tracking audit** ✅
Driven by a report that switching cars mid-session wasn't detected — the
Phase 12 "keep trip alive while moving" rule silently attributed a new
car's entire drive to the old one, since no code ever re-checked which
vehicle's Bluetooth was actually connected during an active trip. Full
audit + two independent adversarial review rounds; see
`docs/TRACKING-AUDIT-2026-06-28.md` for the complete findings/fix record
and `docs/TRACKING-KNOWLEDGE-BASE.md` for the durable design reference.
- **Vehicle-switch detection**: new `checkVehicleSwitch()`, checked on
  every GPS update, every 60s audit tick, and immediately on
  `.newDeviceAvailable` audio route events. Debounced (8s consistent
  detection required) to avoid one-off BLE flicker triggering a false
  switch. Ends the current trip and starts a fresh one for the newly
  detected vehicle, without allowing that new trip to merge into an
  older saved trip for it.
- **Removed a second, conflicting stationary-check** (`checkStationary()`)
  that ended trips purely on elapsed time with no Bluetooth awareness —
  it could fire on stray GPS jitter and cut a trip mid-drive even with
  BT still connected, contradicting the Phase 12 policy. All stationary
  decisions now go exclusively through the BT-aware audit.
- **`locationManagerDidPauseLocationUpdates`** (iOS's own "you're
  stationary" signal in Low Power mode) no longer ends the trip
  unconditionally — it defers to the same BT-aware audit logic.
- **Stricter Bluetooth vehicle matching**: UID match is trusted
  unconditionally; a name-only match is used only if it uniquely
  identifies one active vehicle — if two active vehicles share a BT
  name (a real risk: many head units report generic names like
  "CarPlay"), the app refuses to guess and logs an error asking the
  user to re-pair, rather than silently picking one.
- **Cross-vehicle merge guard**: a trip will not merge into an earlier
  trip for the same vehicle if a *different* vehicle was driven in
  between — closes an A→B→A bounce scenario that could otherwise
  back-date a resumed trip's start time across the other vehicle's
  interlude.
- **Archived vehicles excluded** from all Bluetooth matching and
  fallback-vehicle selection.
- **Active-trip persistence throttled** to once per 3 seconds (was:
  every single GPS callback) to reduce I/O that could otherwise delay
  the very location callbacks this detector depends on.

**Phase 12 — State-based trip-end + velocity logging** ✅
Driven by a field log where real CarPlay drives were chopped into
0.4 / 2.4 km fragments (all ended "stationary 5 min" while CarPlay
was still connected) and a ~3-hour afternoon drive was never recorded
(endless "Verification FAILED"). Root cause: iOS suspends the app
mid-drive, GPS callbacks stop for ~5 min at a time, `lastMovementAt`
goes stale, and the time-based stationary audit ended live trips.
- **State-based keep-alive**: a trip stays active while the car is in
  use — paired Bluetooth connected **OR** the car still moving. It
  ends only when **disconnected AND stationary** past the timeout.
  Traffic-light stops, quiet CarPlay stretches and GPS-stale gaps no
  longer cut a drive short.
- **Robust car-presence detection**: `AudioRoute.isPairedDevicePresent`
  checks the audio route's outputs *and* available inputs, so a
  CarPlay/BT car that's connected but not the active output during a
  quiet stretch is still recognised (fixes the false "BT missing"
  flapping). Vehicle's BT name is stored on the active trip for a
  second matching signal.
- **Route-change no longer ends trips directly**: an
  `.oldDeviceUnavailable` audio event now triggers an audit pass
  (debounce + moving check) instead of an immediate end.
- **Hard safety cap**: even if BT erroneously reads "present", a trip
  ends after 30 min with zero movement.
- **Velocity in the log**: `Trip.lastSpeedKmh` tracked per update; each
  AUDIT heartbeat now logs `v X km/h`, the BT state, GPS freshness,
  and which keep-alive kept the trip open (`BT` / `moving` / `—`).

**Phase 11 — Auto-detect quick toggle on Record screen** ✅
- A prominent on/off card at the top of the Record tab mirrors the
  Settings auto-detect toggle, so the user can stop background
  tracking with one tap when it isn't needed (vacation, weekend,
  personal day) instead of digging into Settings.
- The card shows live status: "Watching for trips" / "Off — trips
  won't be detected" / "Needs 'Always' location — open Settings" /
  "Location denied".
- `TripDetector.setAutoDetect(_:)` is now the single entry point for
  both toggles (Record + Settings): it persists the preference,
  requests notification permission + location when turning on, and
  tears down monitoring when turning off. The old per-toggle logic
  (Settings onChange handler) was removed so the two toggles can't
  double-fire the enable/disable side-effects.

**Phase 10 — Optional Face ID / Touch ID app lock** ✅
- `BiometricAuth` wraps LocalAuthentication; reports the available
  biometry kind (Face ID / Touch ID / none) and authenticates with
  `.deviceOwnerAuthentication` so the device passcode is a fallback —
  the user can never be permanently locked out.
- `AppLock` (ObservableObject) holds the on/off preference in
  UserDefaults (device-local, NOT synced to the cloud — biometric
  choice shouldn't follow the account to other devices) and the
  `isLocked` state.
- `LockView` is a full-screen brand-gradient lock that auto-prompts
  on appear and offers a manual Unlock button.
- `RootView` overlays `LockView` when authenticated + locked, and
  re-locks on `scenePhase == .background` (only `.background`, so the
  Face ID system sheet's `.inactive` phase doesn't false-trigger).
- **Settings → Security** toggle: enabling runs a biometric check
  first and only turns on if it passes; shows a disabled hint when no
  biometry is enrolled on the device.
- Info.plist needs `NSFaceIDUsageDescription` (added to
  InfoPlist.xcstrings, en + sl). The string catalog supplies it when
  localization is enabled; otherwise add the key manually in Xcode.

**Phase 9 — Detector hardening from real-drive logs** ✅
Driven by analysing on-device Detection logs from real trips. Adds:
- **Trip merge**: new trip within 15 min + 300 m of previous end
  resumes that trip instead of fragmenting one real drive into
  multiple rows during brief stops.
- **3-strike BT debounce**: AVAudioSession route wobble no longer
  ends a trip on the first missed read; requires 3 consecutive
  audits with the paired device missing.
- **Verification needs movement**: CoreMotion's automotive signal
  alone isn't enough — also require ≥100 m of GPS distance during
  the verification window. Eliminates false starts where a parked
  phone confuses CoreMotion.
- **Richer verification telemetry**: PASSED/FAILED lines log
  `distance` and `non-car` flag so rejection reasons are obvious.
- **Candidate persistence + stale cleanup**: candidates older than
  2× the verification window are dropped on app launch.
- **Restore resumes GPS + audit**: `restoreActiveTripIfAny` now
  re-starts the location manager and audit timer so trip-end
  detection survives iOS app termination mid-drive.
- **Audit deduplication**: 5-second window suppresses back-to-back
  audit calls from race conditions with route-change handlers.
- **GPS health in heartbeat**: each AUDIT heartbeat now appends
  `GPS Xs ago · acc Ym` for at-a-glance signal diagnostics.
- **BT-miss counter resets** on a successful read or trip end.

**Phase 8a — Energy mode toggle** ✅
- New `EnergyMode` enum in `Models.swift` (`lowPower` / `balanced` /
  `highAccuracy`) with localized labels and summaries.
- `UserSettings.energyMode` persists the preset locally and via the new
  `user_settings.energy_mode` column (`supabase/migration-005-energy-mode.sql`
  with a CHECK constraint on the three rawValues).
- `EnergyMode+CoreLocation.swift` maps each mode to concrete
  `CLLocationManager` settings:
    - lowPower:     `kCLLocationAccuracyHundredMeters` + 50 m filter + iOS auto-pause ON
    - balanced:     `kCLLocationAccuracyNearestTenMeters` + 10 m filter + auto-pause OFF
    - highAccuracy: `kCLLocationAccuracyBest` + 5 m filter + auto-pause OFF
- `TripDetector` applies the preset whenever it starts updating location
  (initial wake, verification phase, confirmed trip start). Detection log
  records which preset was active for each trip.
- `LocationManager` gets an `apply(energyMode:)` method; SettingsView's
  picker pushes changes immediately so the manual recorder is in sync.
- New **Energy mode** section in Settings with a segmented picker + a
  dynamic per-mode explanation footer.

**Phase 8 — Battery, smart customer fill, camera OCR, polished Save** ✅
- **Save buttons** in `TripEditor` and `VehicleEditView` are now branded
  gradient capsules with a clearly disabled state — replaces the iOS 26
  underlined-link rendering that looked broken.
- **Battery**: both `TripDetector` and `LocationManager` switched from
  `kCLLocationAccuracyBest`/`BestForNavigation` to `NearestTenMeters`
  with a 10–20 m `distanceFilter`. Cuts background GPS power by roughly
  half with no real loss of accuracy for road-distance accumulation.
- **Customer auto-fill from learned locations**: `Trip.endLat/endLng`
  added (column already in Supabase schema), persisted on every trip end
  (both auto and manual). New `CustomerSuggester` matches the new trip's
  end coordinates against past trips' end coordinates within 200 m and
  picks the most-frequently-visited matching customer name. Auto and
  manual trip paths both consult it.
- **Receipts**:
  - New `CameraImagePicker` lets the user **take a photo** in addition
    to picking from the library; a confirmation dialog asks which.
  - New `ReceiptScanner` runs on-device OCR via Vision
    (`VNRecognizeTextRequest`) in Slovenian + English, finds amount
    patterns (12,34 / 1.234,56 / etc.), and biases toward lines
    containing "skupaj" / "za plačilo" / "total" / "amount" keywords
    so it locks onto the grand total. Detected amount auto-fills the
    Amount field and shows an "Auto-detected: € X.XX" hint.
  - **No Info.plist additions required if NSCameraUsageDescription is
    already set** (it was added in Phase 5). If not, add
    `Privacy - Camera Usage Description` → *"MileLog uses the camera
    to scan receipt photos."*

**Phase 7 — UX refresh (indigo brand, hero Record, card trips)** ✅
- New `Theme.swift` centralises the brand identity: indigo→blue gradient,
  per-trip-type palette (business=blue, commute=orange, private=gray) and a
  card-surface color + shadow.
- Reusable components added to `UIComponents.swift`:
  - `PulsingDot` — animated "live" indicator
  - `TripTypeChip` — colored capsule badge for the three trip types
  - `.cardStyle()` view modifier for elevated rounded surfaces
- `RecordTripView` redesigned as a hero screen: large gradient circle in the
  center showing the live km readout with `.contentTransition(.numericText())`
  for smooth updates, pulsing dot + descriptor row when a trip is live,
  prominent gradient Start / red gradient Stop button with shadow, soft
  indigo background wash, and a custom vehicle-selector Menu chip at the top.
- `TripsListView` redesigned with card-style rows: colored left edge per trip
  type, headline customer/purpose, route arrow (`From → To`), date · vehicle ·
  km on the bottom, gradient-pill monthly section header showing the business
  total at a glance. Empty state has a large gradient car icon and copy.
- Tab bar uses `.tint(Theme.accent)` so the active tab and selected controls
  pick up the brand color. Tab icons switched to filled variants for a
  modern look.

**Phase 6b — Vehicle lifecycle (archive / restore / delete)** ✅
- `Vehicle.isActive` flag mirrors the existing `vehicles.is_active` column.
  Active vehicles appear in pickers (Record tab, Logbook export, Trip
  editor). Archived ones stay in the database so historical trips keep
  their reference but don't clutter day-to-day flows.
- New `Store.deleteVehicle(_:)` does the smart split: **archive (soft
  delete)** if the vehicle has trips, **hard delete** if it doesn't.
  `Store.restoreVehicle(_:)` reactivates an archived vehicle.
- Explicit **Delete vehicle** button in `VehicleEditView` with a
  confirmation dialog whose copy adapts based on whether trips reference
  the vehicle.
- `VehiclesView` redesigned:
  - Each active row shows a vehicle-type icon and the relative
    last-used date ("2 days ago", "4 months ago", "Never used").
  - An inline orange suggestion banner appears under any active
    vehicle unused for 90+ days: *"Not used in 3+ months. Archive?"* —
    one-tap Archive button.
  - Separate **Archived** section at the bottom shows soft-deleted
    vehicles dimmed with strikethrough; swipe actions offer Restore
    or permanent Delete (with a confirm alert).
- Record-tab vehicle picker, Settings logbook vehicle picker, and the
  default new-trip vehicle all switched from `store.vehicles` →
  `store.activeVehicles`.

**Phase 6a — Pre-PDF trip selection** ✅
- Tapping "Review trips and generate" in either report section navigates to
  `ReportSelectionView` — a checklist of all eligible trips for the period
  with a per-row checkmark + bulk filters (Select all / Deselect all /
  Business only / Commute only).
- The PDF is generated only after the user confirms the subset; ShareLink
  appears inline below the list.
- `PDFReporter` got `ownCarCandidates(...)` and `companyLogbookCandidates(...)`
  helpers so the selection view can pre-compute the eligible set without
  duplicating filter logic. `generateMonthlyOwnCar` and
  `generateCompanyCarLogbook` now consume already-filtered trip arrays.

**Phase 6 — Real-world fixes** ✅
- **Trip-start verification**: significant-location wakes no longer commit to
  a trip immediately. If a known car BT is connected → start (high confidence).
  Otherwise enter a 90-second verification phase that requires either
  `> 25 km/h` sustained speed or a CoreMotion "automotive" signal — filters
  out walks, runs, cycling.
- **Single active trip enforced**: TripDetector refuses to start while another
  trip is active *or* while the manual LocationManager is recording; the
  manual Start button is disabled while the auto detector has a trip in flight.
- **Smarter vehicle fallback**: when no BT match is available, the detector
  uses the vehicle from the user's most recent trip instead of arbitrarily
  picking the first vehicle.
- **Two reimbursement rates**: `UserSettings.reimbursementRate` (business) +
  new `UserSettings.commuteRate`. `Trip.reimbursement(businessRate:commuteRate:)`
  picks per type; private trips reimburse 0.
- **Own-car monthly report**: `PDFReporter.generateMonthlyOwnCar` filters to
  own vehicles + business/commute only, with separate totals and totals line.
  Renamed Settings section to "Own-car monthly report".
- **Company-car logbook (potni nalog)**: new `PDFReporter.generateCompanyCarLogbook`
  draws the standard Slovenian layout (Datum / Ura od / Ura do / Od / Do /
  Namen / km zač. / km kon. / km) with blank odometer + signature blocks for
  handwriting. New "Company car · potni nalog" Settings section, surfaced
  only when at least one vehicle is type `.company`.
- **Migration**: `supabase/migration-004-phase6.sql` adds the `commute_rate`
  column.
- **App icon source**: `assets-source/AppIcon.svg` (speedometer / km motif on
  blue gradient). Convert to a 1024×1024 PNG via any SVG tool, then feed into
  appicon.co (or drop directly into Xcode's `AppIcon` asset catalog and let
  Xcode generate the sizes).
- **Required Info.plist addition**: `Privacy - Motion Usage Description` ↔
  *"MileLog uses motion to confirm you're actually driving before starting
  a trip — this prevents false trip starts when you walk or run."*

**Phase 5 — Localization (Slovenian)** ✅
- `Localizable.xcstrings` (String Catalog) contains every user-facing string
  with English source + Slovenian translation.
- `InfoPlist.xcstrings` localizes the location, camera and photo library
  permission prompts.
- Trip / Vehicle / Receipt enum labels use `String(localized:)` so they pick up
  the user's language at runtime.
- Notification text and PDF report headers are localized so the export the
  user emails to their accountant arrives in the right language.

**One-time Xcode setup for localization**
1. Project navigator → blue **MileLog** project icon → **Info** tab → under
   **Localizations**, click **+** → choose **Slovenian** (sl) → Finish.
2. Drag `Localizable.xcstrings` and `InfoPlist.xcstrings` from `MileLog/` into
   the Xcode sidebar (Copy items if needed → unchecked; target → MileLog).
3. Build & run. To preview the Slovenian UI without changing your iOS device
   language: target → **Scheme → Edit Scheme → Run → Options → App Language →
   Slovenian** → close → run. Revert to "System" to switch back.

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
