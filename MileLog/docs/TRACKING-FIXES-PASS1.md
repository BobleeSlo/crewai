# MileLog Auto-Detect Tracking — Pass 1 Analysis & Fixes

**Source evidence:** `MileLogDetectionLog202607011900.txt` (100 entries, 2026-06-29 → 2026-07-01)
**File changed:** `MileLog/TripDetector.swift`
**Scope of this pass:** deep-scan of the auto-detect trip lifecycle (`TripDetector.swift`) plus its
collaborators (`AudioRoute.swift`, `Models.swift`, `MotionVerifier.swift`, `TripClassifier.swift`,
`LocationManager.swift`, `Store.swift`), cross-referenced line-by-line against the field log.

## How the engine is supposed to work (as designed)

1. `CLLocationManager` significant-location-change wakes the app.
2. If the phone is already connected to a *known* vehicle's Bluetooth, a trip starts immediately.
   Otherwise a "verification" phase gathers GPS speed / CoreMotion signal for up to 90s before
   committing (filters out walks/runs).
3. While a trip is active, GPS updates accumulate distance, and a periodic **audit** (every 60s)
   checks Bluetooth presence and stationary time, ending the trip only when the car is **both**
   Bluetooth-disconnected **and** stationary past the timeout (a deliberate "state-based" policy so
   traffic lights / quiet CarPlay stretches don't cut a real drive short).
4. A 30-minute hard cap force-ends a trip regardless of BT state, as an absolute backstop.

## Issues found

### 1. Vehicle switch was never detected (the reported bug) — **critical**

`auditActiveTrip()` only ever asked "is *my own* trip's paired Bluetooth device still present?"
(`AudioRoute.isPairedDevicePresent(uid:name:)`). It never asked "is a *different* registered
vehicle's Bluetooth connected right now?" Combined with the state-based policy — which explicitly
keeps a trip alive as long as the car is still moving, even if BT reads "missing" — this meant:

- Park car A (trip ends up bound to car A's Bluetooth UID/name).
- Get into car B (a different registered vehicle) and start driving.
- The audit sees car A's BT as "missing" (increments the 3-strike counter) but **also** sees
  `recentlyMoving == true` (because the app is now moving — in car B). The end condition
  `!connected && !recentlyMoving` never becomes true, so **the trip never ends** — car B's entire
  drive gets silently appended to car A's trip until the user notices and force-stops it.

This exactly matches the field log:
```
FORCE-STOP: 143.9 km, 0 min since last movement, BT disconnected (auto-stop should have fired)
FORCE-STOP: 60.8 km, 0 min since last movement, BT disconnected (auto-stop should have fired)
FORCE-STOP: 78.7 km, 0 min since last movement, BT disconnected (auto-stop should have fired)
```
"0 min since last movement" = still driving at the moment of the force-stop — i.e. the trip was
never going to end on its own no matter how long the user kept driving.

**Fix:** `auditActiveTrip()` now checks, on every tick, whether `AudioRoute.currentBluetoothOutput()`
resolves (via the existing `matchVehicle`) to a vehicle **other than** the active trip's vehicle. If
so, it ends the current trip immediately (bypassing the "moving keeps it alive" rule — a positive
match to a specific other registered car is unambiguous, unlike a noisy "missing" reading) and
immediately starts a new trip for the new vehicle at the last known location. This is also wired
into the `AVAudioSession` route-change handler (see #2) for near-instant reaction, not just the
60-second tick.

### 2. Route-change handler ignored `.newDeviceAvailable`

`audioRouteChanged(_:)` only reacted to `.oldDeviceUnavailable` (the old device disappearing). It
never reacted to `.newDeviceAvailable` (a new device — e.g. car B's stereo — appearing), which is
the more direct signal for "a different car just connected." Now both reasons trigger an immediate
audit pass (bypassing the anti-duplicate dedupe window), so a vehicle switch is caught within
seconds of the Bluetooth route changing instead of waiting for the next periodic tick.

### 3. The periodic audit's actual cadence in the field was far slower than its 60s design, breaking the 3-strike debounce and the hard cap

The audit was driven almost entirely by a repeating `Timer`. iOS suspends timers once the app is
backgrounded; they only get a chance to catch up when something else (a location delivery) wakes
the process. The log shows heartbeats landing roughly every **5 minutes**, not every 60 seconds:
```
05:21:13  AUDIT heartbeat ...
05:23:51  AUDIT heartbeat ...
05:28:51  AUDIT heartbeat ...   (5m gap)
05:38:26  AUDIT heartbeat ...
05:43:27  AUDIT heartbeat ...   (5m gap)
```
Consequences:
- The "3-strike" BT-miss debounce (documented/intended as ~3 minutes of real time) actually took
  **~15 minutes or more** in practice, since each "strike" only lands roughly every 5 minutes.
- The 30-minute hard cap is *also* only evaluated inside the audit — so it inherited the same
  unreliable cadence, and in the worst case (continuous driving, so no natural stationary period)
  never fires at all, which is exactly the failure mode behind the three FORCE-STOP entries.

**Fix:** `updateActiveTrip(with:)` now also triggers `auditActiveTrip()` directly, gated to the same
60-second interval, using GPS delivery as the reliable background heartbeat (which is the entire
point of `allowsBackgroundLocationUpdates`). The `Timer` is kept as a secondary path for
foreground/no-movement cases; the location-driven trigger is what makes the debounce and hard-cap
timing match what the code's own comments describe.

### 4. `checkStationary()` silently contradicted the documented state-based policy

`checkStationary()` (called on every GPS update) ended a trip purely on elapsed time since
`lastMovementAt`, with **no regard for Bluetooth connection at all** — directly conflicting with
`auditActiveTrip()`'s explicit, documented design ("keep the trip alive while EITHER the paired
Bluetooth is connected OR the car is still moving"). In principle this could prematurely end a real
trip during a stop with the engine off but BT still paired (many head units stay connected for a
while after ignition-off).

**Fix:** removed `checkStationary()` entirely; its call site now defers to the same
`auditActiveTrip()` used everywhere else (see #3), so there is exactly one trip-end policy instead
of two disagreeing ones. Verified this is not a behavior regression for trips with no BT pairing at
all (`hasPairing == false` makes `auditActiveTrip()`'s decision collapse to the same pure-time check
`checkStationary()` used to do).

### 5. `forceEndTrip()`'s diagnostic message asserted a bug that usually wasn't one

Every FORCE-STOP entry in the log says `"BT disconnected (auto-stop should have fired)"`, hardcoded
whenever `currentBT` was `nil`, without checking whether GPS still showed movement. In two of the
three log occurrences (`0 min since last movement`), the real policy was correctly keeping the trip
open — the message was misdiagnosing intended behavior as a bug, which obscured the actual root
cause (#1) during troubleshooting.

**Fix:** `forceEndTrip()` now mirrors the real decision inputs (`recentlyMoving`, and — new — whether
the currently-connected device belongs to a different known vehicle) so the log accurately reports
*why* the trip was still open: still moving vs. genuinely stuck vs. a vehicle switch that
auto-detect should now catch on its own.

## Not changed (observed, but not app bugs)

- **GPS staleness during highway driving** (log shows `GPS 290–314s ago` while doing 100+ km/h) —
  this is standard iOS background-location throttling once the app isn't in the foreground; the
  project already sets `allowsBackgroundLocationUpdates`, `UIBackgroundModes: location`, and
  `activityType = .automotiveNavigation`, which are the correct mitigations available. No further
  in-app fix changes this; flagged for the second review pass in case there's a setting that helps.
- **~109-minute "stationary" gap before a restore** (line 28–31 of the log) — this is the app having
  been suspended/terminated by iOS during a long period with no qualifying GPS movement, which is
  outside the app's control until the OS relaunches it. The hard-cap and merge logic correctly clean
  this up once the app resumes; this is inherent to iOS background execution limits, not a defect.

## Files changed

- `MileLog/MileLog/TripDetector.swift` — all fixes above.

## Verification status

Reasoned through against the actual field log and the full `TripDetector.swift` state machine;
cross-checked for Swift 6 strict-concurrency/`@MainActor` correctness and re-entrancy (the new
end-then-restart call sequence in `auditActiveTrip()` is fully synchronous, no suspension points in
between). **Not compiled** — this environment has no macOS/Xcode toolchain. A second, independent
pass (adversarial review + additional findings) follows in
`docs/TRACKING-FIXES-PASS2-REVIEW.md`, and an actual Xcode build/run on real hardware is still
required before shipping.
