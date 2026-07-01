# MileLog Tracking Engine — Audit & Fix Record

**Date:** 2026-06-28
**Scope:** `MileLog/MileLog/TripDetector.swift`, `MileLog/MileLog/AudioRoute.swift`
**Trigger:** User report — "if I switch the car and the phone is connected with a different bluetooth system, app does not find this out — it continues to track the trip in false mode," plus a request for a full deep-scan against every instruction given in the build conversation, and an independent adversarial review before considering the work done.

**Process used:** static code audit → fix → independent adversarial review (fresh agent, no memory of the fix rationale) → fix confirmed findings → second independent adversarial review of the round-1 fixes specifically → fix the one remaining gap it found. Two full review passes, two fix passes.

---

## Part 1 — Static audit findings (before any subagent review)

### 🔴 Critical — Vehicle switch was never detected

`handleSignificantLocation` bailed out silently whenever a trip was already active, without ever re-checking which car's Bluetooth was actually connected. `auditActiveTrip` only checked whether the **trip's own** paired device was still present — it never asked "is a *different known vehicle's* Bluetooth connected right now?"

Combined with the "keep trip alive while moving" policy (added in an earlier session to survive iOS suspending GPS mid-drive), the failure mode was: get into car B, start driving → `updateActiveTrip` keeps refreshing `lastMovementAt` because the phone is moving → the end condition (`!connected && !recentlyMoving`) never becomes true → car B's entire drive gets logged against car A indefinitely.

**Fix:** new `checkVehicleSwitch()` method, wired into three places for fast + redundant detection:
- `auditActiveTrip()` (60s timer)
- `updateActiveTrip(with:)` (every GPS callback — near-instant during active driving)
- `audioRouteChanged(_:)` on `.newDeviceAvailable` (fires as soon as iOS routes audio to the new car, typically the fastest signal)

### 🔴 Critical — A second, conflicting stationary-check was never removed

`updateActiveTrip` still called `checkStationary()`, a leftover from before the "keep alive while connected" policy was introduced. It ended trips purely on elapsed time **with no Bluetooth awareness at all** — directly contradicting the newer policy. GPS multipath/jitter routinely produces a spurious position update even while parked at a light with the engine idling; if one landed after the stationary timeout had elapsed, this old code ended the trip **even with Bluetooth still connected**. Very likely a major contributor to the fragmentation seen in prior field logs even after the "keep alive" policy shipped.

**Fix:** removed the call and the function. All stationary-based ending now goes exclusively through `auditActiveTrip()`, which is BT-aware. Cost: up to ~60s of extra detection latency against a multi-minute timeout — an accepted trade for removing a source of incorrect early endings.

### 🟡 `locationManagerDidPauseLocationUpdates` — same bug pattern, different call site

iOS's own "you're stationary, I've paused GPS" callback (fires in Low Power energy mode) ended the trip unconditionally, with the same lack of BT-awareness as the removed `checkStationary()`.

**Fix:** now defers to `auditActiveTrip()` (bypassing its dedupe window) instead of ending directly, so it respects the same connected-or-moving keep-alive logic.

### 🟡 BT matching included archived vehicles

`matchVehicle` and `fallbackVehicle` searched `store.vehicles` (all vehicles, including archived) instead of `store.activeVehicles`. An archived vehicle's stale Bluetooth pairing could silently claim trips.

**Fix:** both now search `store.activeVehicles` only.

### 🟢 Minor — BT-miss warning log spam

Once BT was confirmed gone but the trip stayed open via the "moving" keep-alive, the miss-counter warning re-logged every 60 seconds indefinitely.

**Fix:** the warning now only logs while the 3-strike counter is still counting up (`consecutiveBTMisses <= btMissesToConfirm`); the heartbeat line still reports the ongoing state once per tick without a duplicate warning.

---

## Part 2 — Round 1 independent adversarial review (fresh agent)

Full prompt gave the reviewer no knowledge of *why* the fixes were made — only the current code and a description of what changed, with instructions to try to break it. Findings, with verdicts:

| # | Finding | Verdict | Action |
|---|---|---|---|
| 1 | `matchVehicle`'s name-fallback is exploitable: two vehicles sharing a generic BT name (e.g. "CarPlay" — **confirmed present in the user's own field log**) could be mismatched, especially since wireless CarPlay's reported UID can be session-unstable | **Confirmed, real** | Fixed — see below |
| 2 | A switch-triggered trip's own later *normal* end could still merge forward into a stale trip for the same vehicle, back-dating the start time | Confirmed in round 2 (see Part 4) | Fixed |
| 3 | No debounce on switch-detection — asymmetric with the BT-loss check's 3-strike debounce; a single flickering BLE read could trigger a switch | **Confirmed, real** | Fixed — see below |
| 4 | Consequence of #3: A→B→A flapping could fragment a real drive, and the discarded middle segment (if < 200m) would silently **lose** real distance rather than misattribute it | Confirmed (consequence of #3) | Mitigated by the #3 fix |
| 5 | Verify `checkStationary()` removal doesn't reopen a worse problem | **Checked, sound — no change** | — |
| 6 | `AudioRoute.isPairedDevicePresent` can report "present" for a car parked in the driveway with BT lingering after the engine is off, holding a trip open up to the 30-minute hard cap | Real, but the hard cap already bounds it, and shortening it would work against the user's explicit "keep alive while connected" instruction | **Accepted tradeoff — documented, not changed** |
| 7 | Re-entrancy/actor-isolation safety of `checkVehicleSwitch()`'s synchronous end+restart | **Checked, sound — no change** | — |
| 8 | Overlap between `.oldDeviceUnavailable` and `locationManagerDidPauseLocationUpdates` both bypassing dedupe | Confirmed harmless (second call correctly no-ops via dedupe) | — |
| 9 | `consecutiveBTMisses` reset correctness across all call sites | **Checked, sound — no change** | — |
| 10 | `trip.points` unbounded growth + full-file JSON rewrite on every single GPS callback — real battery/I-O cost, ironic given the goal | **Confirmed, real** | Fixed — see below |
| 11 | `fallbackVehicle()` picking an unregistered-BT vehicle self-corrects once the real vehicle reconnects | Not a defect | — |

### Fixes applied from round 1 review

**A. Tightened Bluetooth identity matching** (`matchVehicle`)
- UID match is trusted unconditionally (most confident signal).
- Name match is used **only if it uniquely identifies exactly one active vehicle**.
- If the connecting device's name matches **two or more** active vehicles, the app now **refuses to guess** and logs an `.error`-level message asking the user to re-pair — rather than silently picking one (which was the exploitable behavior).

**B. Debounced vehicle-switch detection** (`checkVehicleSwitch`)
- New instance state: `pendingSwitchVehicleID` / `pendingSwitchFirstSeenAt`.
- The newly-detected vehicle must be observed consistently for `switchConfirmSeconds = 8` before the app actually acts on the switch.
- This is checked across all three call sites sharing the same instance state, so a confirmation started by an `audioRouteChanged` event is correctly completed by a later GPS update or audit tick.
- Chosen as 8 seconds (not the 3-tick/~180s pattern used for BT-loss) because gain-detection is evaluated far more frequently (every GPS callback) than the loss check (60s audit ticks) — a short wall-clock window gives fast, user-visible response while still filtering out one-off BLE proximity flickers.

**C. Disabled trip-merge on switch-triggered starts** (`commitTripStart(..., allowMerge:)`)
- New `allowMerge: Bool = true` parameter.
- `checkVehicleSwitch()` passes `allowMerge: false` — a detected switch is a discontinuous event by definition, so the new trip must never resurrect/merge into an older saved trip for the "new" vehicle.
- (This alone turned out to be insufficient — see Part 4.)

**D. Throttled active-trip persistence**
- `persistActiveTrip(force: Bool = false)` now only writes to disk once every `persistThrottleSeconds = 3` for routine in-trip updates.
- `force: true` is used at all state-transition moments: fresh trip start, merge-resume, and (via `commitTripStart`) switch-triggered start.
- In-memory data (`activeTrip.points`) is unaffected — only the disk-write *frequency* changed, not what's tracked. Supabase sync at trip-end still gets the complete point set.

---

## Part 3 — Round 2 independent adversarial review (fresh agent, targeting round-1 fixes)

A second, independently-launched reviewer (no memory of round 1's reasoning) was given only the current code and the round-1 change descriptions, and told to specifically attack the *new* fixes.

| # | Finding | Verdict |
|---|---|---|
| 1 | `allowMerge: false` at the switch-triggered trip's *start* doesn't stop that trip's own later *normal end* from merging forward into the pre-switch trip — an A→B→A bounce within `mergeWindowMinutes`/`mergeRadiusMetres` could still stitch car A's mileage across the car-B interlude, back-dating the resumed trip's start time | **Confirmed, real — genuine gap in the round-1 fix** |
| 2 | 8-second debounce can itself be delayed (not bypassed) by BT flapping during the confirmation window, since any non-matching read resets `pendingSwitchFirstSeenAt` to nil | Real but low severity — fails safe (delay, not misattribution); noted, not changed |
| 3 | Debounce state is single, shared, and correctly reset on every exit path across all three call sites | **Checked, sound — no change** |
| 4 | `matchVehicle`'s ambiguity refusal falls through sensibly at every call site (verification, fallback-vehicle, switch-check) rather than dead-ending | **Checked, sound — no change** |
| 5 | Persist-throttle `force: true` correctly placed at all required transition points; worst-case kill window loses at most the tail of one trip, never misattributes it | **Checked, sound — no change** |
| 6 | No dead code, no comment/behavior contradictions found | **Checked, sound** |

### Fix applied from round 2 review

**E. Closed the cross-vehicle merge loophole at the source** (`tryMergeWithRecentTrip`)

Rather than trying to track "was this specific trip switch-triggered" forward through its lifecycle (fragile), the fix addresses the actual invariant that must hold: **a trip for vehicle A must never merge with an earlier trip for vehicle A if a *different* vehicle's trip started in between.**

`tryMergeWithRecentTrip` now checks, before merging: does any trip for a *different* vehicle have a `startedAt` after the candidate merge-target's `endedAt`? If so, merging is refused and logged, regardless of *which* code path triggered the merge attempt (switch-triggered start, normal fresh start, or a future call site not yet written). This closes the gap generally rather than patching one symptom of it.

---

## Part 4 — Final state (all fixes committed)

Total changes to `TripDetector.swift` across both rounds: **~210 lines changed** (new methods, tightened matching, debounce, merge guard, persist throttle). `AudioRoute.swift` also gained `isPairedDevicePresent` (checks route outputs *and* available inputs, so a CarPlay/BT car that drops out of the active audio route during a quiet stretch is still recognized as connected) — this predates this specific audit but is load-bearing for the vehicle-switch fix's correctness, so it's documented here too.

### Verified sound (no change needed) — both review rounds independently agree:
- Actor-isolation / re-entrancy safety of the synchronous end+restart in `checkVehicleSwitch`.
- `consecutiveBTMisses` reset correctness across every call site.
- Removal of the old `checkStationary()` doesn't reintroduce a worse version of what it fixed.
- Persist-throttle placement.
- `matchVehicle` ambiguity-refusal fallthrough behavior.

### Accepted, documented tradeoffs (not changed):
- **30-minute hard cap** on a trip that reads BT-connected but is genuinely stationary (e.g. parked in the driveway with the head unit still bonded). Shortening this would work against the user's explicit instruction to keep trips alive while Bluetooth is connected. The hard cap exists specifically to bound the worst case.
- **8-second switch-confirmation window** can be delayed (not bypassed) by BT flapping during the confirmation itself — fails safe by design (a delay, never a misattribution).

### Known, disclosed limitation:
- Two vehicles whose paired Bluetooth devices report the **exact same name** and whose UID doesn't reliably distinguish them (e.g. certain wireless CarPlay setups) cannot be auto-distinguished by name alone. The app will log a clear `.error`-level message when this happens and ask the user to re-pair. This is an inherent constraint of what AVAudioSession exposes, not a bug in this app's logic.

---

## What to verify on next real drives

1. **Switch a car mid-session** (park car A, get into car B within a few minutes, drive). Expect within ~8-15 seconds of car B's Bluetooth connecting: a `VEHICLE SWITCH confirmed` log line, the old trip ending, and a new trip starting for car B.
2. **A→B→A bounce test** (drive A briefly, switch to B briefly, switch back to A within 15 min at roughly the same spot). Expect: three distinct trips (or the short middle one discarded as noise if under 200m), and the resumed A trip should **NOT** silently span back to the original A trip's start time — check the Detection log for a `Merge skipped: ... was driven after this trip ended` line.
3. **Traffic light / brief stop** with the same car the whole time — trip should stay open continuously (no fragmentation), confirming the `checkStationary()` removal didn't regress anything.
4. **Detection log heartbeats** should show `v X km/h` velocity on every line, and BT state as `connected` / `missing(n)` / `none`.

Export the Detection log after a normal driving day and it will show all of the above directly — every decision this engine makes is logged.
