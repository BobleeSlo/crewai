# MileLog Tracking Engine — Knowledge Base

**Purpose:** persistent reference for anyone (human or agent) auditing, extending, or debugging `TripDetector.swift`. Captures the domain knowledge, iOS platform quirks, and design rationale that this system depends on, so future work doesn't have to re-derive it from scratch. Update this file whenever a new non-obvious constraint or failure mode is discovered.

**Last updated:** 2026-06-28 (after the vehicle-switch audit, see `TRACKING-AUDIT-2026-06-28.md`)

---

## 1. What this system does, in one paragraph

`TripDetector` runs entirely in the background on the user's iPhone. It wakes on iOS "significant location change" events, decides whether the user is actually driving (not walking/running), identifies **which car** via the currently-connected Bluetooth audio device, records the drive's GPS track and distance, and decides when the drive has ended — all without the user touching the app. The output feeds tax/reimbursement reports, so **wrong vehicle attribution or wrong distance has real financial consequences**, not just a UX annoyance.

## 2. The state machine

```
                    significant location change
                              │
                              ▼
                    ┌───────────────────┐
                    │  no active state   │
                    └─────────┬──────────┘
                              │
              ┌───────────────┴───────────────┐
              │ known vehicle's BT connected?  │
              └───────────────┬───────────────┘
                   yes │             │ no
                       ▼             ▼
              ┌────────────┐  ┌─────────────────┐
              │ commit trip │  │ candidate/       │
              │ immediately │  │ verification     │
              │ (fast path) │  │ (slow path, ~90s)│
              └──────┬──────┘  └────────┬─────────┘
                     │                   │ passes (speed OR
                     │                   │ automotive+movement)
                     │                   ▼
                     │           ┌────────────┐
                     └──────────▶│ ACTIVE TRIP │
                                 └──────┬──────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    │                   │                    │
            BT confirmed gone    vehicle switch        stationary hard
            AND stationary       detected (debounced)  cap (30 min)
                    │                   │                    │
                    ▼                   ▼                    ▼
              trip ends,          trip ends, NEW         trip ends
              saved/discarded     trip starts for
              (merge eligible)    new vehicle
                                  (merge disabled)
```

## 3. Core design principle: state-based, not time-based, trip ending

**The single most important rule in this file.** A trip must stay open while the car is genuinely in use, and "in use" is defined as: **Bluetooth connected OR the car still moving**. A trip ends only when **both** are false: disconnected AND stationary past the timeout.

This was arrived at the hard way. An earlier design ended trips purely on "N minutes since last movement," which is fragile because:
- GPS multipath/jitter routinely produces a spurious position update even while parked at a light with the engine idling.
- iOS suspends the app's background execution for minutes at a time, so "time since last movement" can silently include long stretches where the app simply wasn't running to observe movement at all.

**Rule for anyone touching this file:** if you're tempted to add a new "end the trip if X minutes have passed" check anywhere other than inside `auditActiveTrip()`, don't. Every stationary-based decision must go through that one function, which is the only place that correctly weighs BT presence against elapsed time. This exact mistake (a second, BT-unaware stationary check bypassing the audit) was found and removed twice in the 2026-06-28 audit — once as `checkStationary()`, once as `locationManagerDidPauseLocationUpdates` ending the trip directly. **Watch for a third instance if new iOS delegate callbacks are ever added.**

## 4. Known iOS/CoreLocation/AVAudioSession quirks that shape this code

| Quirk | Where it matters | How the code handles it |
|---|---|---|
| iOS suspends background apps for minutes at a time, even with location permission "Always" | GPS updates and `Timer`s (audit timer, verification deadline) can all silently stop firing | Verification checks wall-clock elapsed time on every update it *does* receive, not just its own `Timer`; `restoreActiveTripIfAny()` resumes GPS + audit on relaunch after a kill |
| `CLLocationManager` does not call `didUpdateLocations` while the device hasn't moved past `distanceFilter` | A truly parked phone generates ~zero location callbacks | This is *why* removing the per-update `checkStationary()` was safe — there's rarely anything to trigger it incorrectly during genuine stillness; the 60s audit timer is the sole real backstop |
| `pausesLocationUpdatesAutomatically` (only true in Low Power energy mode) fires `locationManagerDidPauseLocationUpdates` when iOS itself decides the device is stationary | This is a strong "stopped" signal, but NOT a strong "disconnected" signal | Must still defer to the audit's BT-aware logic — see rule in §3 |
| `AVAudioSession.currentRoute.outputs` only lists the device currently carrying **audio output** — during a quiet stretch (no music, no nav voice) a connected car can drop out of it | A naive `currentBluetoothOutput()`-only check falsely reports "BT missing" mid-drive | `AudioRoute.isPairedDevicePresent` also scans `availableInputs`, which keeps listing a genuinely-connected device even when it's not the active output |
| `availableInputs` can still list a paired car as "available" for a grace period after the engine is off (varies by head unit — some minutes, some indefinitely while accessory power is on) | A car parked in the driveway can hold a trip open long after the driver has walked away | The 30-minute `stationaryHardCapMinutes` bounds the worst case; deliberately not shortened because the user explicitly wants trips to stay open while BT is connected — see §6 |
| Wireless CarPlay's reported audio-route **UID can be session-unstable**, while the **name is often generic** ("CarPlay") and shared across completely different vehicles | Two different cars can present as indistinguishable via name, and even UID matching can silently fail on a session where the UID rotated | `matchVehicle` trusts UID unconditionally when available, but refuses to guess when a name matches 2+ registered vehicles (logs an `.error` telling the user to re-pair) rather than picking one arbitrarily |
| `AVAudioSession.RouteChangeReason` fires `.newDeviceAvailable` / `.oldDeviceUnavailable` fairly promptly when a BT audio route actually changes | This is the fastest available signal for "car changed" | Vehicle-switch detection is hooked into this notification for near-instant response, in addition to the audit timer and every GPS callback (belt-and-suspenders, given the financial stakes) |
| `Timer.scheduledTimer` does not fire while the app is suspended | The 90s verification deadline and 60s audit timer are unreliable clocks in the background | Verification checks elapsed wall-clock time on every location update it receives, not relying solely on its own Timer firing on schedule |

## 5. Threshold reference (as of 2026-06-28)

| Constant | Value | Why |
|---|---|---|
| `verificationSeconds` | 90s | Max time to decide "is this really a drive" before giving up |
| `speedConfirmKmh` | 25 km/h | Speed above which we trust it's driving, not walking/cycling |
| `automotiveMovementMetres` | 100m | Minimum GPS distance required alongside CoreMotion's "automotive" signal — the signal alone is unreliable for passengers/near-miss false positives |
| `btMissesToConfirm` | 3 (audits, ~60s apart ⇒ ~3 min) | Debounce for "BT genuinely gone," since brief transient disconnects (interrupting phone call, momentary route reshuffle) are common and shouldn't end a trip |
| `switchConfirmSeconds` | 8s | Debounce for "a DIFFERENT vehicle's BT genuinely connected." Shorter than the loss-debounce because it's evaluated far more often (every GPS callback, not just every audit tick) — a short wall-clock window still filters one-off BLE flicker while staying fast enough to feel instant to the user |
| `movingSpeedKmh` | 3 km/h | Speed above which the car counts as "moving" for keep-alive purposes |
| `stationaryHardCapMinutes` | 30 min | Absolute backstop — ends a trip even if BT still reads "connected," bounding the worst case of a lingering-BT false positive (§4) |
| `minTripKm` (in `endTrip`) | 0.2 km | Trips shorter than this are discarded as GPS noise, not saved |
| `mergeWindowMinutes` / `mergeRadiusMetres` | 15 min / 300m | A new trip for the same vehicle starting within this time+distance of the previous trip's end is treated as a continuation, not a new row — prevents one real drive with a brief stop (lunch, fuel, customer visit) from fragmenting into many rows |
| `auditIntervalSeconds` | 60s | Cadence of the backstop audit that re-evaluates BT presence, stationary time, and vehicle identity |
| `auditDedupeWindow` | 5s | Prevents the audit from double-firing when a route-change event nudges it right after the timer already ran |
| `persistThrottleSeconds` | 3s | Disk-write throttle for the in-progress-trip crash-recovery file, to avoid a full JSON rewrite on every single GPS callback |

**If you change any of these, re-run the adversarial review methodology in §8 before shipping** — several of the bugs found in this audit were exactly "a threshold or debounce that looked fine in isolation but interacted badly with another part of the system."

## 6. Explicit design decisions the user has made (don't silently override these)

- **"No trip ending until velocity is still present... continuous until Bluetooth is active and car is moving."** This is the origin of the entire state-based keep-alive policy in §3. Any future change that makes trips end more eagerly on elapsed time alone contradicts this and should be flagged back to the user, not just implemented.
- **Fast detection of vehicle switches is a priority** — the user explicitly complained that switching cars silently mis-tracked. This is why the switch-detection debounce (§5, 8s) is deliberately much shorter than the loss-detection debounce (3 min), even though a fully symmetric design would use the same window for both.
- **The 30-minute hard cap should not be shortened** without asking the user first — doing so trades away the "keep alive while connected" guarantee they explicitly asked for, in favor of tighter false-positive control they haven't asked for.

## 7. Where the money/tax-report risk actually lives

Three places in this codebase have a direct line to what appears on a tax/reimbursement report, and deserve the most scrutiny in any future change:

1. **`vehicleID` on the saved `Trip`** — wrong vehicle here is silently wrong tax treatment (own-car vs. company-car rates differ). This is what the entire vehicle-switch fix was about.
2. **`distanceKm`** — silently lost distance (e.g. a flapped-away middle segment discarded as noise) understates a legitimate business trip.
3. **`startedAt`** — a back-dated start time (the cross-vehicle merge bug found in round 2) misrepresents *when* a vehicle was actually being driven, which matters for day-based logbook rules (e.g. "which car was used on which day").

Any change to `checkVehicleSwitch`, `tryMergeWithRecentTrip`, `matchVehicle`, or `endTrip` should be checked against all three before merging.

## 8. Audit methodology used (repeat this pattern for future rounds)

1. **Static read-through** of the full file(s) in question, cross-referenced against every explicit instruction the user has given historically (not just the most recent one — requirements accumulate across a long-running conversation and can conflict with later, unrelated changes if not tracked).
2. **Fix what's clearly broken** based on the static read.
3. **Independent adversarial review**: launch a fresh subagent with NO memory of the fix rationale — give it only the current code and a factual description of what changed and why (not a defense of why it's correct). Ask it to actively try to break it, not confirm it works. This catches blind spots the original implementer can't see because they're anchored on their own mental model of the fix.
4. **Verify every subagent finding against the actual code** before acting on it — don't blindly implement suggested fixes. In this audit, several findings were confirmed correct-as-designed (not bugs) after verification, and one finding (the 30-minute hard cap) was consciously NOT changed because doing so would contradict an explicit user requirement, even though the reviewer flagged it as a real limitation.
5. **Second independent review pass, targeting the round-1 fix specifically** — verifies the fix didn't introduce new problems, and often finds a narrower, deeper gap in the fix's own logic (in this case: merge-forward after a switch, which the round-1 fix hadn't considered because it was focused on the switch moment itself, not the switched-trip's eventual natural end).
6. **Document everything** — both the audit trail (what was found, what was fixed, what was consciously left alone and why) and durable knowledge (this file) — so the NEXT round doesn't have to rediscover iOS quirks or re-litigate design decisions the user already made.

This file and its accompanying audit record are the output of following that process once. Keep both updated as the system evolves.
