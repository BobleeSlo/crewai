# MileLog Auto-Detect Tracking — Pass 2: Adversarial Review & Fixes

Independent second pass, per the requested process: a specialized reviewer (acting as a senior
iOS/Swift/CoreLocation/AVFoundation engineer) re-examined the actual patched `TripDetector.swift`
from pass 1 against the field log and the codebase, without taking pass 1's own write-up at face
value. This document records what the review found and what was changed as a result.

## Review verdict on pass 1

**The core vehicle-switch fix works for the primary reported scenario** — switching to a different
*registered* vehicle mid-drive is now detected and acted on promptly (via the audit tick, the
GPS-driven trigger, and the route-change handler), closing the "switches car, app doesn't notice"
complaint for the common case. Several things from pass 1 were checked and confirmed sound:
the `checkStationary()` → `auditActiveTrip()` fold does not meaningfully regress no-BT trips (at
most a ~60s delay, bounded by `auditIntervalSeconds`); the GPS-driven audit trigger correctly
prevents dense-city GPS bursts from accelerating the 3-strike debounce; the synchronous
`endTrip()` → `commitTripStart()` sequence has no reentrancy hazard and is safe under this class's
`@MainActor` isolation; `forceEndTrip()`'s rewritten message is accurate; the
`AVAudioSession.RouteChangeReason` API usage is correct.

The review also found three real issues, all now fixed.

## Issues found in round 2 and fixes applied

### 1. CONFIRMED — the route-change handler's dedupe bypass was unconditional, not one-shot

`audioRouteChanged(_:)` set `lastAuditAt = .distantPast` on **every** `.oldDeviceUnavailable` /
`.newDeviceAvailable` event before calling `auditActiveTrip()`. A burst of route-change
notifications — e.g. a phone call renegotiating the HFP profile, or repeated CarPlay
reconnect/disconnect churn — invokes this handler several times within the same second. Each call
individually reset and then immediately re-passed the dedupe guard, so the "3 consecutive misses"
counter (meant to represent roughly 3 minutes of real disconnection, per the 60s audit interval)
could reach 3 within seconds during such a burst instead, ending a real trip on a transient BT
hiccup. `AudioRoute.isPairedDevicePresent`'s scan of `availableInputs` (not just the active output)
tempers how often this would actually bite in practice — a car's paired HFP mic input often stays
visible through a call's route churn — but the underlying logic did not protect against it at all.

**Fix:** `audioRouteChanged(_:)` no longer bypasses `lastAuditAt`/`auditDedupeWindow`. It just calls
`auditActiveTrip()` directly. This is safe because of fix #2 below: the vehicle-switch check now
runs unconditionally, *before* the dedupe gate, so a genuine switch is still caught instantly; only
the BT-miss counter and heartbeat logging (the part that must stay rate-limited) respect the gate.

### 2. Confirmed gap — vehicle switch to an *unconfigured* car reproduced the original bug

The pass-1 fix only recognized a switch when the newly-connected Bluetooth device resolved (via
`matchVehicle`) to a different **registered** vehicle. If the new car was never given a Bluetooth
pairing in Settings, `matchVehicle` returns `nil`, the switch branch never fired, and — because GPS
still showed movement — the old trip could run indefinitely against the wrong vehicle, exactly
reproducing the reported failure for any not-yet-configured car.

**Fix:** `auditActiveTrip()` now also recognizes "a specific, different Bluetooth device is
connected that isn't the trip's own paired device, and doesn't match any registered vehicle
either." That's still definitive evidence the car changed (a concrete other device is occupying
the audio route, not merely "missing"), so the old trip is ended immediately. Unlike the
known-vehicle case, it does **not** guess which vehicle the new drive belongs to — it lets the
ordinary wake/verification path (already used for any trip start with no BT match) pick that up
once GPS moves again, the same way it already resolves ambiguous cases. This is scoped to trips
that started with *some* BT identity recorded (`hadPairing`), so a trip that began with no BT
signal at all isn't spuriously ended just because an unrelated Bluetooth accessory (e.g.
headphones) transiently connects.

### 3. PLAUSIBLE — ambiguous name-based vehicle matching could misattribute a switch

`matchVehicle(for:)`'s Bluetooth-name fallback (used when the UID doesn't match, e.g. after a
CarPlay UID reshuffle) picked `store.vehicles.first(where: bluetoothName == device.name)`. If two
registered vehicles happen to share an identical generic head-unit name (e.g. two of the same car
model, both showing up as "Toyota Touch 2 with Go" — exactly the kind of string seen in the actual
field log), a reshuffle on the vehicle that's *actually* being driven could resolve to the *other*
same-named vehicle instead, depending on array order. Previously this only affected which vehicle a
fresh trip start was attributed to; now that a resolved match can also immediately end an
in-progress trip (the pass-1 fix), the consequence of a bad match is more severe — a false
"vehicle switch" ending a real drive.

**Fix:** the name-based fallback in `matchVehicle` now only trusts the match when it's unambiguous
— if more than one vehicle shares that exact Bluetooth name, it returns `nil` rather than
arbitrarily picking the first array entry. This applies uniformly to both trip-start matching and
the new switch-detection logic.

## Reviewed and accepted (no change needed)

- `tryMergeWithRecentTrip` (invoked by the new vehicle-switch's `commitTripStart` call) filters
  only by `vehicleID`, so a same-day trip on the new vehicle that ended nearby within the merge
  window could get resumed/backdated. This is existing, intentional merge behavior applied
  consistently everywhere trips start — changing it specifically for the switch path would make
  vehicle-switch-started trips behave inconsistently with every other trip start. Left as-is.
- The Vehicle data model has no uniqueness constraint on `bluetoothName` at the UI/edit layer. The
  code-level mitigation (fix #3) makes an ambiguous match safe (falls through to `nil` instead of
  guessing), which is the appropriate scope for a tracking-logic fix; enforcing uniqueness in the
  "add/edit vehicle" UI would be a separate, larger product change.

## Files changed (this pass)

- `MileLog/MileLog/TripDetector.swift` — fixes #1, #2, #3 above.

## Verification status

Reasoned through by an independent reviewer against the actual patched source and the field log,
tracing concrete scenarios (known-vehicle switch, unconfigured-vehicle switch, duplicate-name
collision, route-change burst) rather than re-stating pass 1's claims. Findings were fed back and
fixed in this same pass, then re-read end-to-end for consistency (brace/scope correctness, no
duplicate/shadowed locals, dedupe-gate ordering). **Still not compiled** — no macOS/Xcode toolchain
is available in this environment. An actual Xcode build, plus real-device testing of the two-car
switch scenario (ideally with two Bluetooth-paired vehicles, and at least one deliberately
*unpaired* vehicle to exercise fix #2), is required before shipping.
