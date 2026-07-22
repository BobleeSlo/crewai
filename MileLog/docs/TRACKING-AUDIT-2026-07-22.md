# MileLog Tracking Engine — Audit & Fix Record (Phase 16)

**Date:** 2026-07-22
**Scope:** `MileLog/MileLog/TripDetector.swift`
**Trigger:** User field log `MileLogDetectionLog202607221819.txt` (100 entries, all from a single day) plus explicit report: "why are there issues with trip ending, but bluetooth was still active and the car was moving."

---

## Part 1 — What the log actually shows

The Phase 15 fix (proactive notification on Always→While-Using downgrade) is confirmed working: every trip-start block in this log shows `Location authorization changed: always`, and no "whenInUse" lines appear anywhere. Permission is no longer the problem in this log.

Instead, this log shows a NEW, more severe pattern: the app process itself is being terminated and relaunched by iOS repeatedly during a single continuous drive. Tracing the timeline:

| Time range | What happened |
|---|---|
| 03:19–04:45 | Trip running normally: heartbeats every ~5 min, `BT connected`, speeds up to 120 km/h, distance climbing steadily to 77.7 km |
| 04:45 → 05:46 (**61 min gap, zero log lines**) | `Restored in-progress trip after relaunch` fires, immediately followed by `AUDIT: ending trip — stationary 61 min`. Trip ends at 81.0 km, classified Private |
| 05:46 → 10:47 (5 hours) | A verification candidate started at 05:46 sits unresolved until finally cleared as stale at 10:47 — almost certainly a genuine long stop (car parked for hours), not a continued-driving gap, based on the much longer duration and the pattern matching the already-documented "fully stationary + suspended app" behavior |
| 10:47–10:52 | Trip runs normally, ends normally at 10:57 after a genuine 5-minute stop (5.5 km, Business) — this is the ONE trip in the whole log that ended the expected way |
| 10:57 → 11:26 (**24 min gap**) | Same pattern: trip running (0.2 km logged, `v 60 km/h`), then silence, then relaunch + immediate stationary-timeout ending (1.5 km, Business) |
| 11:26 → 12:36 (**30 min gap**) | Same pattern again (41.1 km, Business) |
| 12:36 → 13:31 (**45 min gap**) | Same pattern again (4.9 km, Business) |
| 13:31 → 16:19 (**168 min gap**, log export triggered the final audit) | Trip discarded as noise (0.07 km) |

Four separate relaunch-triggered endings in one day, three of them (24, 30, 45 min) immediately following heartbeats that showed live, connected, moving driving. Per the user's direct report, this was one continuous drive with Bluetooth connected throughout — meaning the vehicle almost certainly kept moving through most or all of each gap, and the resulting 5.5 km / 1.5 km / 41.1 km / 4.9 km trip rows are fragments of what should have been one or two real trips.

## Part 2 — Why this happens, and what is and isn't fixable from the app's code

**The trip-end decision itself is not the bug.** `auditActiveTrip()` correctly computes "how long since the app last observed movement" and correctly ends the trip once that exceeds the timeout — there's no flaw in that arithmetic. The real problem is upstream: **the app process is losing execution (being killed, not just briefly suspended) far more often and for far longer than an app continuously receiving background location updates should.** iOS grants apps using `allowsBackgroundLocationUpdates` + active location updates essentially uninterrupted background runtime specifically so this doesn't happen — routine "iOS suspends background apps for minutes at a time" (already documented) does not normally explain 24–61 minute *full terminations* clustered this tightly during confirmed continuous driving.

Two things worth checking that are **outside this codebase and outside what I can verify from here** (this repository doesn't contain the Xcode project file, only the Swift sources):

1. **"Location updates" Background Mode capability.** In Xcode: select the MileLog target → *Signing & Capabilities* → *Background Modes* → confirm **"Location updates"** is checked. If this capability isn't enabled, `CLLocationManager.allowsBackgroundLocationUpdates = true` (set in `commitTripStart`, `resumeTrip`, and `restoreActiveTripIfAny`) can cause the app to be terminated once it's no longer in the foreground — which would produce exactly this pattern: works fine right after each relaunch, dies again once the phone is locked/backgrounded, gets relaunched by the next significant-location-change, repeat.
2. **Low Power Mode.** If the phone was in Low Power Mode during this drive (Settings → Battery), iOS is markedly more aggressive about suspending/killing background apps, independent of anything MileLog's code does.
3. **Xcode's device crash logs** (Window → Organizer → select the device → *View Device Logs*, search "MileLog") would definitively confirm whether these are real crashes rather than OS-throttling — worth checking after the next drive if the pattern continues even with (1) and (2) ruled out.

None of these three can be fixed from this repository — they're Xcode project configuration and iOS system settings on the user's own Mac/phone.

## Part 3 — What was fixed in code regardless of root cause

Whatever the underlying cause of the terminations turns out to be, there will always be *some* residual risk of the app losing execution mid-drive, and the existing brief-stop merge logic (15 min / 300 m) was never designed to absorb a gap of tens of minutes at highway speed. Rather than loosen those general tolerances (which would risk merging genuinely separate, coincidentally-timed trips), a **targeted recovery path** was added:

- `auditActiveTrip()` now takes an `isPostRelaunch` flag, true only for the one immediate audit run right after `restoreActiveTripIfAny()` resumes a persisted trip on a fresh app launch — never on a normal, continuously-running 60-second tick.
- When a stationary-timeout ending happens specifically via that post-relaunch audit, the closed trip's identity (`tripID`, `vehicleID`, true last-movement time) is remembered in `relaunchRecoveryContext`, because a closure reached this way is fundamentally less trustworthy than a normal live-observed one — the app was dead for the whole gap and has no idea whether the car kept moving.
- The very next trip start for the **same vehicle**, within `relaunchRecoveryWindowMinutes` (90 minutes — comfortably above the worst confirmed gap in this log, 61 minutes, without being so generous it risks merging two truly separate later trips), reclaims that exact trip directly — bypassing the normal 15-minute/300-metre limits entirely, since same-vehicle-immediately-after is itself strong evidence of a continuation rather than a coincidence. A different vehicle driven in between still correctly blocks the reclaim (mirrors the existing cross-vehicle merge guard).
- The previously-duplicated "resurrect a saved trip into an active one" code (shared by the normal merge and this new path) was extracted into one `resumeTrip(...)` helper.

This does not fix *why* the app is losing execution — only the Xcode/iOS-side checks above can address that — but it means that **if** the underlying cause persists, a single real drive fragmented by relaunches will merge back into one accurate trip instead of showing up as several small, wrongly-bounded rows.

## Part 4 — Independent adversarial review

*(Findings from a dedicated review of this change — merge-safety, race conditions, and the coordinate-fallback logic — recorded below once complete.)*

## What to verify next

1. **Check the three items in Part 2** (Background Modes capability, Low Power Mode, device crash logs) — these determine whether the underlying termination frequency can be reduced at all.
2. **After the fix, a drive interrupted by a relaunch** should show a `Reclaiming trip interrupted by app relaunch` log line and end up as ONE trip in the trips list, not several.
3. **A genuine, deliberate stop** (e.g., arriving at a real destination, turning the car off, walking away for well over 90 minutes) followed by a **separate, later drive in the same vehicle** should still produce two distinct trips, not one incorrectly merged trip — worth spot-checking once there's a normal (non-relaunch-interrupted) day of driving to confirm no over-merging regression.
