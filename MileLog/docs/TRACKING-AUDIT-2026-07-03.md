# MileLog Tracking Engine — Audit & Fix Record (Phase 14)

**Date:** 2026-07-03
**Scope:** `MileLog/MileLog/TripDetector.swift`
**Trigger:** User field log `MileLogDetectionLog202607030713.txt` — a single trip ran continuously for **~19.5 hours and 131.7 km**, spanning **4 app-kill/relaunch cycles**, and only ended because the user manually tapped force-stop. No automatic end ever fired.

**Supersedes:** the trip-end design documented in `TRACKING-AUDIT-2026-06-28.md` (Phase 12/13). That design is now known to be actively wrong and must not be reintroduced. See `TRACKING-KNOWLEDGE-BASE.md` for the corrected, current design principle.

---

## Part 1 — What the user reported and required

Direct quotes from the field-log review request:

> "Tracking should start, no matter if the bluetooth is connected or not. It should be triggered, if the moving speed is like driving the car."
>
> "Bluetooth shall be used for detecting the vehicle — in this way the app can connect trip detection and specific car (private car, business car)"
>
> "There is a problem by detecting end of trip. This is not working correctly."
>
> "Make analyse of the app and repair it."

This is a direct reversal of the Phase 12 policy ("keep the trip alive while Bluetooth reads connected OR the car is moving"), which had itself been adopted in good faith from an earlier explicit user instruction ("There shall be no trip log ending, until the velocity is still present... continuous until the bluetooth is active and car is moving"). Real field data has now shown that instruction's premise — that a connected-Bluetooth reading reliably reflects "the car is still in use" — is false in practice: car head units stay Bluetooth-bonded for hours after the engine is off and the driver has left. The Phase 12 design let that stale "connected" reading override an otherwise-correct stationary detection, indefinitely.

## Part 2 — Root cause analysis

Traced against the field log:

- The trip's `auditActiveTrip()` heartbeat lines repeatedly showed a growing "minutes since movement" figure (into the double digits, at one point noted around 18+ minutes) alongside `BT connected`, and the old end condition (`!connected && !recentlyMoving`) never went true because `connected` stayed true — the paired car's Bluetooth simply never read as disconnected for the rest of the day.
- The 30-minute `stationaryHardCapMinutes` backstop *should* have caught this, but it was measured from `lastMovementAt`, and evidently something in the sequence of app-kill/relaunch cycles kept resetting or outrunning that measurement window across the 4 relaunches — each relaunch resumes the trip and restarts the audit timer, but (prior to this fix) only evaluated on the *next* 60-second tick rather than immediately, so a trip that was actually long over at relaunch time could sit unevaluated for up to a full audit interval before its first post-relaunch check, repeated across 4 relaunches.
- Net effect: a policy designed to tolerate real-world stops (red lights, quiet CarPlay stretches) instead tolerated the car being parked and the driver being gone for the rest of the day, because it trusted a signal (BT "connected") that doesn't actually mean what the design assumed it means.

## Part 3 — Fix applied

**Bluetooth is now identification-only. It has zero influence on whether a trip is considered ongoing.**

1. **`auditActiveTrip()` rewritten** — the entire BT-presence / 3-strike-debounce / "connected-or-moving keep-alive" / 30-minute-hard-cap block was deleted. The function now does exactly one thing to decide whether the trip is over: `stationaryMin = minutes since trip.lastMovementAt; if stationaryMin >= store.settings.stationaryTimeoutMinutes { end trip }`. No override, no exception, no cap to reconcile against — because there is only one rule now, it cannot be outrun by a lingering BT reading.
2. **Removed as obsolete:** `consecutiveBTMisses`, `btMissesToConfirm`, `stationaryHardCapMinutes`, and every reset call-site for the first of those (in `commitTripStart`, `tryMergeWithRecentTrip`'s resume path, and both exit branches of `endTrip`).
3. **`checkVehicleSwitch()` extended** to fulfill the "Bluetooth identifies the vehicle" rule even for trips that started without Bluetooth (the common case now, since trip start no longer waits for or depends on BT — see next point). When the newly-detected BT device's matched vehicle is the **same** vehicle already assigned to the active trip, the trip immediately adopts that device's UID/name (no debounce needed, since nothing about the trip's classification or lifetime is changing) rather than only handling the "different vehicle" switch case as before.
4. **Trip start was already rule-compliant and untouched**: `handleSignificantLocation` starts a candidate/verification cycle (speed > 25 km/h, or CoreMotion "automotive" activity plus 100m+ of GPS movement, confirmed within 90 seconds) regardless of whether any Bluetooth is connected. A connected known vehicle's BT is only used as a same-instant fast path to skip the verification wait — it was never a precondition for starting.
5. **`restoreActiveTripIfAny()`** now calls `auditActiveTrip()` immediately after restarting the audit timer, instead of waiting for the next 60-second tick. This directly targets the observed failure pattern of multiple app-kill/relaunch cycles across one long field-log trip — each relaunch is now itself a chance to promptly close out a trip that has actually been over for a long time, rather than a missed opportunity that silently extends it further.
6. All doc comments referencing the old "keep alive while connected," "3-strike debounce," and "30-minute hard cap" design were rewritten throughout the file (class header, `auditActiveTrip`, `forceEndTrip`, `checkVehicleSwitch`, `audioRouteChanged`, `locationManagerDidPauseLocationUpdates`, `ActiveTripState.lastSpeedKmh`) so no stale rationale is left for future readers to trust by accident.

Commit: `5bd176d` — "MileLog Phase 14: pure movement-based trip end, Bluetooth is identification-only" on branch `claude/upbeat-brahmagupta-NXMLR`.

## Part 4 — Why this doesn't reintroduce the problem Phase 12 was trying to solve

Phase 12 existed to stop real drives from being cut short by red lights and quiet CarPlay stretches. Pure movement-based ending still handles this correctly, because it was never actually the mechanism that handled it:

- A red light is a stop of at most a minute or two — far under `stationaryTimeoutMinutes` (Settings-configurable, default single digits of minutes). The trip simply never approaches the timeout during a normal stop-and-go drive.
- If a real stop (e.g. a long ferry crossing, a multi-vehicle-in-one-day mixed session) ever does exceed the timeout and produces two trip rows instead of one, `tryMergeWithRecentTrip` (Phase 13, unchanged by this fix) stitches them back together automatically — provided no *other* vehicle's trip started in between (that cross-vehicle guard, closed in Phase 13 Part 3, is independent of and unaffected by this change).
- What Phase 12's BT-based extension actually did in practice was mask exactly the failure mode it was meant to prevent: instead of gracefully splitting-and-merging a long real stop, it silently ran a stale trip for the rest of the day because BT told it "still connected" long after that stopped being true. Pure movement-based ending plus the existing merge logic is a strictly better solution to the same original problem.

## Part 5 — Independent adversarial review (round 3) and follow-up fixes

A fresh reviewer (no memory of the fix rationale, specialized in iOS/CoreLocation/AVFoundation background execution) was given the Phase 14 diff and the three-rules requirement, and told to trace actual execution paths rather than summarize the diff. Verdict on the three rules: rule 1 (BT-independent start) and rule 2 (BT for identification) **confirmed satisfied**; rule 3 (end-of-trip fixed) **only partially satisfied as originally shipped** — the reported bug was genuinely fixed, but the reviewer traced two real regressions that got much more real-world exposure specifically *because* Phase 14 now ends trips on ordinary ≥5-minute stops instead of keeping them alive via Bluetooth.

| # | Finding | Severity | Verdict | Action |
|---|---|---|---|---|
| 1 | `tryMergeWithRecentTrip` restored a merged/resumed trip's `startLat/startLng` from the **previous leg's END coordinates**, not its true origin — `Trip` never had start coordinates at all (`endLat/endLng` existed, no `startLat/startLng`, even though the Supabase `trips` table already had unused `start_lat`/`start_lng` columns). Every merge (which now happens far more often under pure movement-based ending) silently fed the wrong "start" into `TripClassifier`'s home/work proximity check and the reverse-geocoded start address — a real commute could misclassify as business/private after one ordinary stop | **High** | **Confirmed, real** | Fixed — see below |
| 2 | The pure GPS-timing stationary check can't distinguish "genuinely parked" from "GPS went dark while still driving" (tunnel, underground garage, or the app's own documented background-suspension gaps) — both simply stop producing location callbacks. A real drive through a tunnel longer than `stationaryTimeoutMinutes` (default 5) would auto-end mid-drive and permanently lose that segment's distance, since the reacquired GPS point is usually too far from the old trip's last point to pass the merge-radius check | **High** | **Confirmed, real** | Fixed — see below |
| 3 | On merge, the previous leg's `RecordedPoint`s (map polyline) are discarded — `deleteTrip`'s cascade removes `trip_points`, and the resumed `ActiveTripState.points` is reseeded with a single fresh point. `distanceKm` carries forward correctly, so this is map/UX-only, not a mileage or tax-figure defect | Medium | Confirmed, real | **Accepted, documented — not fixed this round** (see below) |
| 4 | `RecordTripView.swift`'s live tracking banner still read "Ends on Bluetooth disconnect or after N min stationary" — directly contradicts the shipped design and is user-visible, not just an internal comment | Medium | Confirmed, real | Fixed — see below |
| 5 | The new same-vehicle BT-adoption branch had no debounce and used `persistActiveTrip(force: true)`, unlike the genuine-switch path's 8s debounce. Traced in detail: the existing `matchesCurrentPairing` OR-check (UID *or* name match) already prevents repeat writes unless BOTH differ simultaneously, so the "every GPS update forces a write" framing was too broad — but dropping the forced write anyway costs nothing and matches the persist-throttle rationale elsewhere in the file | Low–Medium | Confirmed narrower than reported, but real | Fixed — see below |
| 6 | When a trip starts via motion-only verification with a guessed vehicle (`fallbackVehicle()`), and Bluetooth later reveals a *different* actual vehicle, the correction goes through the discontinuous switch/split path (end + new trip) rather than a simple relabel — not a Phase 14 regression itself, but Phase 14's own start-path exercises this more since BT-independent starts are now the norm | Low–Medium | Confirmed, pre-existing | **Accepted, documented — not changed this round** (see below) |
| 7 | Stale doc comment on the `auditTimer` property still said "ends the trip if either of the normal triggers (stationary, BT disconnect) failed to deliver" | Low | Confirmed | Fixed |
| 8 | Dead property `stationaryTimer: Timer?`, unused anywhere in the file | Low | Confirmed | Fixed |

Everything else the reviewer checked — the Phase 13 cross-vehicle merge-forward guard, audit-timer lifecycle across all three trip-becomes-active call sites, `checkVehicleSwitch`'s value-type write-back safety, Swift 6 `@MainActor` patterns in the new/modified code, and whether removing `stationaryHardCapMinutes` reduces protection on its own — came back sound, no change needed.

### Fixes applied from round 3 review

**F. Restored true trip-origin coordinates through a merge** (`Models.swift`, `SupabaseDTO.swift`, `TripDetector.swift`)
- Added `startLat`/`startLng` to the `Trip` model (mirroring the existing `endLat`/`endLng` pattern) and wired them into `TripDTO` — the Supabase `trips` table already had `start_lat`/`start_lng` columns (present in `schema.sql` since early on) that the Swift layer had simply never populated.
- `endTrip()` now sets `trip.startLat`/`startLng` from the active trip's true start, alongside the existing end-coordinate assignment.
- `tryMergeWithRecentTrip()` now restores `lastTrip.startLat`/`startLng` (falling back to the old, imprecise `endLat`/`endLng` behavior only for a trip saved before this field existed) instead of always using the previous leg's end point.
- Also populated for manually-recorded trips (`RecordTripView.finalizeTrip`) for consistency, since the column exists for exactly this purpose.

**G. GPS-blackout protection via CoreMotion, still zero Bluetooth involvement** (`MotionVerifier.swift`, `TripDetector.swift`)
- The core tension: pure GPS-timing cannot distinguish "genuinely parked" from "GPS signal lost while still driving," because `CLLocationManager` stops delivering callbacks in both cases. Re-introducing Bluetooth to disambiguate this (as Phase 12 effectively did) was ruled out — it's exactly the mechanism the user asked to remove, and for good reason.
- Instead, `MotionVerifier` (CoreMotion's `CMMotionActivityManager`, already used for trip-start verification) now exposes `lastAutomotiveActivityAt`, a live timestamp refreshed on every "automotive" classification. CoreMotion runs on the accelerometer/co-processor — it doesn't need GPS or Bluetooth, so it keeps reporting correctly through a tunnel or a background-suspension gap.
- CoreMotion monitoring now runs for a trip's **full duration** (previously it stopped the instant verification passed) — started unconditionally in `commitTripStart` (covers the BT fast-path too, which used to never start it) and only stopped in `endTrip`.
- `auditActiveTrip()`: when the pure elapsed-time check says "stationary past timeout," it now checks whether CoreMotion has reported automotive activity within the last `motionSignalFreshnessSeconds` (120s). If so, the trip is very likely still being driven through a GPS dead zone, and the trip is NOT ended — just logged. This is still movement evidence, not Bluetooth, so rule 3 remains fully compliant.
- Bounded by `gpsBlackoutOverrideCapMinutes` (45 min): even with CoreMotion still reporting automotive, a trip stationary-by-GPS for longer than this ends anyway, so a stuck or misclassifying sensor can't keep a trip open forever — the same worst-case-bounding role the old `stationaryHardCapMinutes` played, but driven by a second movement signal instead of Bluetooth.
- Heartbeat log line extended with a `motion` field (`automotive Ns ago` / `no signal yet`) so this is directly visible in exported Detection logs.

**H. Stale UI text fixed** (`RecordTripView.swift`): the live-tracking banner now reads "Ends after N min stationary," matching the shipped design.

**I. Dropped unnecessary forced write in the BT-identity-adoption branch** (`checkVehicleSwitch`): uses the routine 3s persist throttle instead of `force: true`, since adopting a BT identity is diagnostic metadata, not a state transition requiring an immediate write.

**J. Cleanup**: removed the dead `stationaryTimer` property; corrected the `auditTimer` property doc comment and the `// MARK: - Audit` section header, both of which still described the old BT-disconnect-based design.

### Consciously not fixed this round (documented tradeoffs)

- **Finding #3 (points lost on merge)** — map-polyline-only, doesn't touch `distanceKm` or classification. A correct fix requires either awaiting the previous leg's `pushTripPoints` before any merge-delete, or refactoring `tryMergeWithRecentTrip` to pull the previous leg's points back from Supabase and carry them forward — both non-trivial changes to a currently-synchronous function, better done as their own reviewed change with device testing rather than folded in here.
- **Finding #6 (guess-then-split instead of guess-then-relabel)** — pre-existing behavior, not a Phase 14 regression. Fixing it well requires deciding how much trip history should be eligible for a "silent" vehicle relabel (a resumed/merged trip? one that's covered significant distance already?) — a design question worth its own pass rather than a rushed change here.

## What to verify on the next real drives

1. **A full work day with multiple stops** (customer visits, lunch, fuel) — confirm each stop under the stationary timeout keeps the trip open, any stop over it correctly produces a clean merge (or two intentionally separate trips if a different vehicle was used in between), and the merged trip's start address/classification still reflects the ORIGINAL start point, not the stop's location.
2. **Park the car and walk away, leaving Bluetooth connected** (e.g. leave the phone in the car, or a head unit known to stay bonded for a while) — the trip MUST end automatically once `stationaryTimeoutMinutes` elapses, regardless of what the Detection log reports for BT state. This is the direct regression test for the 19.5-hour bug.
3. **Drive through a long tunnel or underground garage** (or anywhere GPS reliably drops for several minutes while genuinely still driving) — the trip should NOT end mid-drive; the Detection log should show a "GPS dead zone, not ending" line, and the heartbeat's `motion` field should show a recent "automotive" reading.
4. **Switch cars mid-session** — same test as the Phase 13 audit; should be unaffected by this change.
5. **Start a trip without Bluetooth ever connecting** (e.g. phone not yet paired at drive start) — confirm the trip still starts via the speed/motion verification path, runs, and ends purely on the movement timeout, with no BT dependency anywhere in its lifecycle unless/until a known vehicle's BT connects (in which case it should be adopted for identification, logged as "Vehicle confirmed via Bluetooth").
6. **Kill the app mid-trip and relaunch after a long, genuinely stationary gap** — confirm the trip ends promptly on relaunch (via the new immediate post-restore audit) rather than continuing to accumulate distance/time silently.
