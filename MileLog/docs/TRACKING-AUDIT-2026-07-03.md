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

## Part 5 — Independent adversarial review (round 3)

*(See appended section below once the review agent's findings are incorporated — findings, verdicts, and any resulting fixes are recorded here.)*

## What to verify on the next real drives

1. **A full work day with multiple stops** (customer visits, lunch, fuel) — confirm each stop under the stationary timeout keeps the trip open, and any stop over it correctly produces a clean merge (or two intentionally separate trips if a different vehicle was used in between).
2. **Park the car and walk away, leaving Bluetooth connected** (e.g. leave the phone in the car, or a head unit known to stay bonded for a while) — the trip MUST end automatically once `stationaryTimeoutMinutes` elapses, regardless of what the Detection log reports for BT state. This is the direct regression test for the 19.5-hour bug.
3. **Switch cars mid-session** — same test as the Phase 13 audit; should be unaffected by this change.
4. **Start a trip without Bluetooth ever connecting** (e.g. phone not yet paired at drive start) — confirm the trip still starts via the speed/motion verification path, runs, and ends purely on the movement timeout, with no BT dependency anywhere in its lifecycle unless/until a known vehicle's BT connects (in which case it should be adopted for identification, logged as "Vehicle confirmed via Bluetooth").
5. **Kill the app mid-trip and relaunch after a long, genuinely stationary gap** — confirm the trip ends promptly on relaunch (via the new immediate post-restore audit) rather than continuing to accumulate distance/time silently.
