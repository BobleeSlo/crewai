# MileLog Tracking Engine — Audit & Fix Record (Phase 17)

**Date:** 2026-07-22
**Scope:** `MileLog/MileLog/TripDetector.swift`, `LocationManager.swift`, `Store.swift`
**Trigger:** User request to recheck the entire engine with a dedicated Xcode/iOS-specialist critical review agent, score its confidence numerically, and iterate fixes until the score exceeds 95%.

This is a first-principles review — not diff-focused like prior rounds — covering the full current state of the engine after Phases 14–16.

---

## Round 1 review: Success Score 35/100

Two Critical findings, each a deterministic violation of one of the three architectural rules under completely ordinary conditions (not edge cases):

### Critical

1. **`restoreActiveTripIfAny()` never restarts CoreMotion.** `MotionVerifier` is freshly constructed every app launch; it's only ever started from `commitTripStart()`, which a *restored* trip (after an app relaunch) never passes through. Result: for the rest of that process's life, `motion.lastAutomotiveActivityAt` stays `nil`, so the GPS-blackout override in `auditActiveTrip()` can never fire — a trip resumed after a relaunch (exactly the scenario Phase 16 was built around) has ZERO protection against ending mid-tunnel/dead-zone. **Fixed**: added `if motion.isAvailable { motion.start() }` to the restore path.

2. **`fallbackVehicle()`'s guess feeds directly into merge/reclaim vehicle-identity checks.** `matchVehicle` deliberately refuses to guess (returns `nil`) when there's no BT device connected at all, or when a name ambiguously matches 2+ vehicles — but its only caller (`finishVerification`) immediately substitutes `fallbackVehicle()` (heuristic: "whichever vehicle was most recently driven") right afterward, and passes that guess straight into `tryMergeWithRecentTrip`'s vehicle-equality checks for BOTH the normal merge and the relaunch-recovery reclaim. Concrete failure: drive a BT-paired business car, park, then drive a private car with no BT stereo at all within the merge window — `fallbackVehicle()` returns the business car (just driven), and the entire private drive gets merged into the business trip, extending its distance and keeping its original start time. This directly corrupts the business/private split that is the app's core purpose, for any vehicle without a reliably/immediately-connecting BT pairing. **Fixed**: `finishVerification` now tracks whether the vehicle came from a confirmed BT match or a fallback guess, and passes `allowMerge: false` whenever it's a guess — the trip still starts (with the best available guess, manually correctable via the classify notification), but can no longer silently absorb a different, confirmed trip.

### High

3. **Non-atomic JSON writes across the whole persistence layer** (`persistActiveTrip`, `persistCandidate`, `persistRelaunchRecoveryContext` in `TripDetector.swift`; `save()` in `Store.swift`, including the historical `trips.json`). None used `.atomic`, so a kill mid-write (this app has confirmed, field-documented cases of frequent termination) can leave a truncated file; every read site swallows the decode failure with `try?`. For `trips.json` specifically, `load()` silently falls back to an empty array on decode failure, and the *next* `save()` from any future edit would permanently overwrite the last good copy with that empty state — total loss of trip history. **Fixed**: added `options: .atomic` to all six writes (plus the CSV export, for consistency).

4. **`ActiveTripState`'s synthesized `Decodable` doesn't apply property defaults for missing JSON keys** — a well-known Swift gotcha (only `Optional`-typed properties get an implicit `decodeIfPresent`; this codebase already knows this and protects `Vehicle`/`UserSettings` with a hand-written `init(from:)`, but `ActiveTripState` never got the same treatment). `lastSpeedKmh`/`points` were added in later phases; an `active-trip.json` written by an older build and read by an updated one — i.e., exactly the moment the user updates the app mid-trip — would fail to decode entirely, silently losing the in-progress trip. `restoreActiveTripIfAny()`'s decode failure also had no log line at all. **Fixed**: `ActiveTripState` now has the same custom `init(from:)` pattern as `Vehicle`/`UserSettings`, and a decode failure on restore now logs an `.error`.

### Medium

5. **`relaunchRecoveryContext` is a single slot, silently overwritten** if a second trip gets relaunch-flagged before the first is reclaimed. **Fixed**: logs a warning when overwriting a still-valid, unconsumed context (a full per-vehicle map was judged not worth the added complexity for how rare two overlapping interruptions in one session would be).
6. **`persistCandidate()`'s naming/comments oversold real crash-recovery** (only `startedAt` is persisted; `self.candidate` is never rehydrated, only checked for staleness) and `stopMonitoring()` never cleared the file, leaving it to self-heal only after 180s on the next launch. **Fixed**: `stopMonitoring()` now calls `clearPersistedCandidate()`; comment rewritten to state plainly what this does and doesn't do.
7. **Unordered fire-and-forget Supabase calls could orphan a cloud row.** `resumeTrip`'s delete and `endTrip`'s async-geocode-then-update both target the same trip ID with no ordering guarantee between the two independent network calls — if the update's upsert lands after the delete, it resurrects a row that should no longer exist. **Fixed** by removing the delete entirely: `distanceKm` only ever grows across a resume, so whenever the resumed trip truly ends, the normal `pushTrip` upsert (same ID) naturally overwrites the stale row with final data — no delete was needed to get there, and removing it removes the race outright.

### Low

8. Silent trip loss if `finishVerification` passes but zero vehicles are registered at all — **fixed**, now logs `.error`.
9. `store`/`log` held as `unowned` with no retain cycle to justify the crash risk — **fixed**, changed to plain strong references.
10. `LocationManager` was the one piece of location-handling code not using this codebase's `@MainActor` + `nonisolated`-delegate-plus-`Task`-hop pattern (relying instead on CoreLocation's undocumented "callbacks land on the creation thread" behavior). **Fixed** for consistency — mirrors `TripDetector`'s already-proven pattern exactly. Verified safe against `RecordTripView`'s synchronous property access by confirming the exact same pattern (a View struct with no explicit `@MainActor` synchronously reading a `@MainActor`-isolated `TripDetector`'s properties) already compiles and ships successfully elsewhere in this same file.
11. `matchVehicle`/`fallbackVehicle`'s ambiguous-name refusal path — **checked, not a defect**, the refusal logic itself is correct; the bug was entirely in how the caller consumed its `nil` result (finding #2).

### Checked and refuted (reviewer flagged, verified NOT an issue)

- **`trip_points` orphaning under a reused trip ID after merge**: `schema.sql` confirms `trip_points.trip_id references trips(id) on delete cascade` — the cascade already removes old points when the old row is deleted (moot now that the delete itself was removed per fix #7, but confirms this was never actually a live risk).
- **`MotionVerifier`'s CoreMotion closure concurrency**: flagged by the reviewer as unverifiable without a real compiler. Not changed — this exact closure pattern (capturing `self` directly, no `nonisolated`+`Task` hop) already existed before this session's CoreMotion work and has been building and running successfully in the field across many prior phases, which is strong empirical evidence it already compiles cleanly under this project's actual (unknown-to-us) Swift concurrency settings. Changing it without being able to verify against a real build was judged higher-risk than leaving it.

## Round 2 review: Success Score 52.5/100

A fresh, independent reviewer (no memory of round 1's fixes) verified all four round-1 target fixes were genuinely and correctly implemented, then traced the same scenarios further and found one new Critical and two new High findings.

Tally: 1 Critical (−15), 2 High (−16), 3 Medium (−12), 3 Low (−4.5) = 100 − 47.5 = **52.5%**

### Critical

1. **Any single decode failure in `Store.swift` permanently destroys that file's data on the very next `save()`.** `load()` swallowed a decode failure with `try?`, leaving the corresponding `@Published` property at its empty/default value — indistinguishable from "file never existed." `save()` unconditionally rewrites all three files (`vehicles.json`/`trips.json`/`settings.json`) on every single mutation, not just the one that changed — so a `vehicles.json` decode failure gets overwritten with a single default vehicle **on the very next launch** (line 38-41's first-launch seeding logic doesn't distinguish "genuinely empty" from "failed to decode"), permanently destroying every historical vehicle record and orphaning every trip's `vehicleID`. A `trips.json`/`settings.json` failure is equally permanent, just delayed until the next mutation (extremely frequent — any new auto-detected trip, any settings tweak). `.atomic` writes (already correctly used everywhere) rule out a kill-mid-write as the trigger, but not a genuinely incompatible future schema change — and this app has already been through multiple model migrations. **Fixed**: `load()` now distinguishes "file absent" (`Data(contentsOf:)` itself fails — fine, first launch) from "file present but undecodable" (backs the corrupted file up to `<name>.corrupted.json` before letting it be silently overwritten, and prints a diagnostic).

### High

2. **`endTrip`'s async reverse-geocode-then-`updateTrip` is a blind whole-struct overwrite (lost-update race).** The captured `trip` snapshot gets replayed via `storeRef.updateTrip(t)` whenever geocoding finishes — regardless of what's happened to that trip in the meantime. Two concrete failure paths: (a) the user taps a quick-classify notification action before the geocode Task resolves, and their correction gets silently reverted back to the original auto-classification; (b) worse, directly relevant to the relaunch-recovery mechanism — a post-relaunch trip closure's geocode Task can stall (no explicit `CLGeocoder` timeout, and can be stalled by the exact tunnel/dead-zone conditions that caused the relaunch in the first place); if it resolves *after* that same trip has been reclaimed, driven further, and re-ended for real, the stale Task's `updateTrip` silently clobbers the correct, final, merged record with the old short first-leg data — no error, no log, just quietly wrong mileage. **Fixed**: the Task now looks up whatever is *currently* stored for that trip ID at completion time and patches only the two address fields onto it, instead of replaying an old snapshot; no-ops harmlessly if the trip is gone entirely.
3. **`relaunchRecoveryMinGapMinutes` (a bare constant, 15) was decoupled from the user-configurable `stationaryTimeoutMinutes` (2-20 min range).** The outer check already guarantees `stationaryMin >= timeout` before this guard is ever reached — so for any user with a timeout configured above 15 minutes (fully within the supported range), the "only flag anomalously large gaps" safety guard collapsed to a complete no-op, and even a perfectly ordinary stop barely over their own configured timeout would arm the reclaim. **Fixed**: renamed to `relaunchRecoveryMinGapAboveTimeoutMinutes` and the threshold is now computed as `timeout + 15` at the call site, scaling with the user's actual setting rather than a fixed absolute number. Documented tradeoff: for a user near the top of the range, the resulting threshold (up to 35 min) can exceed the smallest field-confirmed app-kill gap (23 min), so some real relaunch fragmentation for that user won't auto-heal — accepted deliberately, since under-merging (an extra, correctly-attributed trip row) is far cheaper than over-merging (silently corrupting a genuinely separate trip).

### Medium

4. **`fallbackVehicle()`'s guess had no log line** distinguishing it from a confirmed BT match, unlike `matchVehicle`'s existing warning for a name-only match — a silently wrong vehicle attribution had zero trace in the Detection log. **Fixed**: logs a `.warning` whenever the vehicle came from the fallback guess rather than a confirmed match, naming the guessed vehicle so it's correctable.
5. **`persistActiveTrip` re-serialized the entire, unboundedly-growing `points` array on every throttled write** (every 3s for a trip's full duration) — real CPU/I-O cost that scales with trip length, on the same actor that has to process time-critical GPS callbacks, undercutting the very reason the throttle was introduced. **Fixed**: split persistence into a lightweight header (written every 3s as before, points-free) and the points array itself (written only every 30s, or on a forced state-transition write) to two separate files; `restoreActiveTripIfAny()` reassembles both on restore. Worst case on a kill: up to 30s of polyline missing, never the whole trip.
6. **A quick-classify notification tap silently no-ops if the trip has since been merged back into an in-progress trip** (`resumeTrip` removes it from `store.trips`) — `NotificationManager.handleAction`'s existence guard just returned with no feedback. **Fixed**: `NotificationManager` now holds a `weak var detector: TripDetector?` (wired in `MileLogApp.init()`); when the trip isn't found, it now logs explicitly whether it's because the trip is back in progress (will be reclassified when it next ends) or gone for some other reason — the tap is still lost either way (there's nowhere to store a classification on an in-progress `ActiveTripState`, which doesn't carry a type yet), but it's no longer silent/undiagnosable.

### Low

7. A corrupted `active-trip.json` was logged on decode failure but never deleted, re-logging the same failure on every future relaunch. **Fixed**: now clears the file in the failure branch.
8. `Trip` — the single most consequential model in the app — was the one model *not* given the hand-rolled `Codable` hardening already applied to `Vehicle`/`UserSettings`/`ActiveTripState` (its `id: UUID = UUID()` default wouldn't apply if the key were ever missing from JSON). **Fixed**: same `init(from:)` pattern applied, all Trip construction call sites verified compatible.
9. The relaunch-recovery reclaim path's trip lookup skipped the `!isLocked` filter the normal merge path has (currently unreachable — the 90-minute window is always far smaller than any realistic lock-after-days setting — but latent). **Fixed** for consistency.

## What's next

A third, independent review round is in progress to verify these fixes and re-score.
