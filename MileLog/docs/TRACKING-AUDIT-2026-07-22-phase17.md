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

## What's next

A fresh, independent review agent (no memory of this round) will re-check the current state end to end. If it scores above 95%, this phase is done; if not, repeat.
