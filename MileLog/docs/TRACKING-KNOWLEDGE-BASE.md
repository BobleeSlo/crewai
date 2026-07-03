# MileLog Tracking Engine — Knowledge Base

**Purpose:** persistent reference for anyone (human or agent) auditing, extending, or debugging `TripDetector.swift`. Captures the domain knowledge, iOS platform quirks, and design rationale that this system depends on, so future work doesn't have to re-derive it from scratch. Update this file whenever a new non-obvious constraint or failure mode is discovered.

**Last updated:** 2026-07-03 (after the Phase 14 trip-end redesign, see `TRACKING-AUDIT-2026-07-03.md`). **Sections 2, 3, 5, and 6 below were rewritten on that date — the design they now describe (pure movement-based trip ending, Bluetooth as identification-only) is a deliberate reversal of the "BT keep-alive" policy this file previously documented. If you are reading a stale copy or a cached summary of this file, discard anything about "keep alive while Bluetooth connected" — that policy caused a real-world ~19.5-hour, 131.7 km false trip and has been removed.**

---

## 1. What this system does, in one paragraph

`TripDetector` runs entirely in the background on the user's iPhone. It wakes on iOS "significant location change" events, decides whether the user is actually driving (not walking/running), identifies **which car** via the currently-connected Bluetooth audio device, records the drive's GPS track and distance, and decides when the drive has ended — all without the user touching the app. The output feeds tax/reimbursement reports, so **wrong vehicle attribution or wrong distance has real financial consequences**, not just a UX annoyance.

## 2. The state machine (current, Phase 14)

```
                    significant location change
                              │
                              ▼
                    ┌───────────────────┐
                    │  no active state   │
                    └─────────┬──────────┘
                              │
              ┌───────────────┴───────────────┐
              │ known vehicle's BT connected?  │   ← fast-path shortcut only;
              └───────────────┬───────────────┘     BT is NEVER required to start
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
              stationary          vehicle switch       BT of already-
              past timeout        to a DIFFERENT       assigned vehicle
              (pure elapsed       vehicle detected      newly seen →
              time since          (debounced)           adopt UID/name
              movement —                                (identification
              BT plays no                                only, doesn't
              role at all)                                touch lifetime)
                    │                   │                    │
                    ▼                   ▼                    ▼
              trip ends,          trip ends, NEW         trip stays open,
              saved/discarded     trip starts for        now tagged with
              (merge eligible)    new vehicle             the right vehicle's
                                  (merge disabled)         BT identity
```

Bluetooth appears in exactly two places in this diagram: as a same-instant fast path to skip verification at start, and as the identification signal for which vehicle a trip belongs to. It does not appear anywhere in the end-of-trip decision.

## 3. Core design principle: pure movement-based trip ending; Bluetooth is identification-only

**The single most important rule in this file, and it has changed once already — read the history below before you consider "improving" it.**

**Current rule (Phase 14, 2026-07-03):** a trip ends when, and only when, `stationaryTimeoutMinutes` have elapsed since `lastMovementAt`. Bluetooth state has **zero** influence on whether a trip is considered ongoing. Bluetooth's only job anywhere in this system is **identification** — deciding which vehicle (private car, business car) a trip belongs to, both at start (fast path) and mid-trip (`checkVehicleSwitch`'s "adopt" and "switch" branches).

**History — why this changed, and why the previous rule must not come back:**

An earlier design (Phase 12, superseded) defined "in use" as **Bluetooth connected OR the car still moving**, ending a trip only when both were false. The intent was reasonable — the user had asked for trips not to end just because of a red light or a quiet CarPlay stretch with no route-change event. But it rested on a false assumption: that a "Bluetooth connected" reading reliably means the driver is still using the car. Field data proved otherwise — car head units routinely stay Bluetooth-bonded for **hours** after the engine is off and the driver has left the vehicle. This let a single day's driving get logged as one 131 km, ~19.5-hour "trip" that never ended on its own, because the stale "connected" reading kept overriding an otherwise-correct stationary detection, across four separate app-kill/relaunch cycles. See `TRACKING-AUDIT-2026-07-03.md` for the full incident.

The lesson generalizes: **do not let Bluetooth presence/absence gate, extend, or override the trip-end decision, ever, no matter how reasonable-sounding the justification.** If a future user request sounds like "keep the trip open while X electronic signal says the car is in use," treat that as a request to revisit `stationaryTimeoutMinutes` and/or `tryMergeWithRecentTrip`'s merge window — NOT as license to reintroduce a BT (or any other non-movement) override into `auditActiveTrip()`. Flag the tension back to the user explicitly rather than silently re-adding it.

**Rule for anyone touching this file:** if you're tempted to add a new "end the trip if X minutes have passed" check anywhere other than inside `auditActiveTrip()`, don't. Every stationary-based decision must go through that one function, which is now the *only* place that decides trip lifetime, using exactly one signal (elapsed time since movement). Two earlier mistakes of introducing a second, competing stationary check outside `auditActiveTrip()` were found and removed in the 2026-06-28 audit (`checkStationary()`, and `locationManagerDidPauseLocationUpdates` ending trips directly) — **watch for a third instance if new iOS delegate callbacks are ever added.**

## 4. Known iOS/CoreLocation/AVAudioSession quirks that shape this code

| Quirk | Where it matters | How the code handles it |
|---|---|---|
| iOS suspends background apps for minutes at a time, even with location permission "Always" | GPS updates and `Timer`s (audit timer, verification deadline) can all silently stop firing | Verification checks wall-clock elapsed time on every update it *does* receive, not just its own `Timer`; `restoreActiveTripIfAny()` resumes GPS + audit on relaunch after a kill |
| `CLLocationManager` does not call `didUpdateLocations` while the device hasn't moved past `distanceFilter` | A truly parked phone generates ~zero location callbacks | This is *why* removing the per-update `checkStationary()` was safe — there's rarely anything to trigger it incorrectly during genuine stillness; the 60s audit timer is the sole real backstop |
| `pausesLocationUpdatesAutomatically` (only true in Low Power energy mode) fires `locationManagerDidPauseLocationUpdates` when iOS itself decides the device is stationary | This is a strong "stopped" signal | Defers to `auditActiveTrip()` rather than ending directly — see rule in §3. (Historical note: this used to matter for BT-awareness reasons; it no longer does, since `auditActiveTrip()` doesn't consider BT at all — the reason to defer now is simply "there's one function that decides trip-end, don't duplicate its logic.") |
| `AVAudioSession.currentRoute.outputs` only lists the device currently carrying **audio output** — during a quiet stretch (no music, no nav voice) a connected car can drop out of it | A naive `currentBluetoothOutput()`-only check falsely reports "BT missing" for identification purposes mid-drive | `AudioRoute.isPairedDevicePresent` also scans `availableInputs`, which keeps listing a genuinely-connected device even when it's not the active output. **This no longer affects trip lifetime (Phase 14) — it only affects how reliably the app can identify/confirm which vehicle is being driven.** |
| `availableInputs` can still list a paired car as "available" for a grace period after the engine is off (varies by head unit — some minutes, some indefinitely while accessory power is on) | This is exactly what caused the Phase 12 → Phase 14 redesign: a car parked in the driveway held a trip open for ~19.5 hours because the design trusted this signal for trip lifetime | **As of Phase 14, this quirk no longer matters for trip-end at all** — Bluetooth presence/absence isn't consulted in `auditActiveTrip()`. It's now purely a fact about identification reliability (a "connected" reading might be stale, so don't be surprised if a vehicle still shows as BT-identifiable well after the drive ended — harmless, since it doesn't extend anything) |
| Wireless CarPlay's reported audio-route **UID can be session-unstable**, while the **name is often generic** ("CarPlay") and shared across completely different vehicles | Two different cars can present as indistinguishable via name, and even UID matching can silently fail on a session where the UID rotated | `matchVehicle` trusts UID unconditionally when available, but refuses to guess when a name matches 2+ registered vehicles (logs an `.error` telling the user to re-pair) rather than picking one arbitrarily |
| `AVAudioSession.RouteChangeReason` fires `.newDeviceAvailable` / `.oldDeviceUnavailable` fairly promptly when a BT audio route actually changes | This is the fastest available signal for "car changed" | Vehicle-switch detection is hooked into this notification for near-instant response, in addition to the audit timer and every GPS callback (belt-and-suspenders, given the financial stakes) |
| `Timer.scheduledTimer` does not fire while the app is suspended | The 90s verification deadline and 60s audit timer are unreliable clocks in the background | Verification checks elapsed wall-clock time on every location update it receives, not relying solely on its own Timer firing on schedule |

## 5. Threshold reference (as of 2026-07-03, Phase 14)

| Constant | Value | Why |
|---|---|---|
| `verificationSeconds` | 90s | Max time to decide "is this really a drive" before giving up |
| `speedConfirmKmh` | 25 km/h | Speed above which we trust it's driving, not walking/cycling |
| `automotiveMovementMetres` | 100m | Minimum GPS distance required alongside CoreMotion's "automotive" signal — the signal alone is unreliable for passengers/near-miss false positives |
| `stationaryTimeoutMinutes` (Settings-configurable) | user-set, single-digit minutes by default | **The sole trip-end criterion.** Elapsed minutes since `lastMovementAt` past this value ends the trip — no override, no exception. See §3. |
| `switchConfirmSeconds` | 8s | Debounce for "a DIFFERENT vehicle's BT genuinely connected" (a real vehicle switch mid-trip). Evaluated on every GPS callback and route-change event — a short wall-clock window filters one-off BLE flicker while staying fast enough to feel instant to the user. (Adopting BT identity for the SAME already-assigned vehicle needs no debounce — see `checkVehicleSwitch` in TripDetector.swift — since it doesn't change the trip's classification or lifetime.) |
| `movingSpeedKmh` | 3 km/h | Speed above which `lastMovementAt` is refreshed — i.e. above which the car counts as "moving" right now |
| `minTripKm` (in `endTrip`) | 0.2 km | Trips shorter than this are discarded as GPS noise, not saved |
| `mergeWindowMinutes` / `mergeRadiusMetres` | 15 min / 300m | A new trip for the same vehicle starting within this time+distance of the previous trip's end is treated as a continuation, not a new row — prevents one real drive with a brief stop (lunch, fuel, customer visit) from fragmenting into many rows. This is what actually absorbs "long stop" cases now, not a Bluetooth override |
| `auditIntervalSeconds` | 60s | Cadence of the backstop audit that re-evaluates stationary time and vehicle identity. Also re-run immediately (bypassing the timer) on app relaunch (`restoreActiveTripIfAny`), on `.oldDeviceUnavailable` route changes, and on `locationManagerDidPauseLocationUpdates` |
| `auditDedupeWindow` | 5s | Prevents the audit from double-firing when a route-change event or relaunch nudges it right after the timer already ran |
| `persistThrottleSeconds` | 3s | Disk-write throttle for the in-progress-trip crash-recovery file, to avoid a full JSON rewrite on every single GPS callback |

**Removed in Phase 14 (do not reintroduce):** `btMissesToConfirm` (was 3 audits ⇒ ~3 min) and `stationaryHardCapMinutes` (was 30 min) — both were part of the BT-keep-alive policy that caused the 19.5-hour false trip. There is no longer a "hard cap" as a distinct concept because the single movement-based timeout no longer needs one to reconcile against.

**If you change any of these, re-run the adversarial review methodology in §8 before shipping** — several of the bugs found in this audit were exactly "a threshold or debounce that looked fine in isolation but interacted badly with another part of the system."

## 6. Explicit design decisions the user has made (don't silently override these)

- **(SUPERSEDED 2026-07-03 — kept here as history, not as current guidance)** "No trip ending until velocity is still present... continuous until Bluetooth is active and car is moving." This had been the origin of the Phase 12 BT-keep-alive policy. Real field data (the 19.5-hour/131.7 km false trip) showed the premise behind it was wrong, and the user explicitly reversed it: **"Bluetooth shall be used for detecting the vehicle... There is a problem by detecting end of trip. This is not working correctly."** The current, correct rule is in §3: pure movement-based ending, Bluetooth for identification only. If you find yourself wanting to cite the old quote above to justify a change, stop — it has been explicitly overridden by the user's own later instruction.
- **Trip start must never depend on Bluetooth.** "Tracking should start, no matter if the bluetooth is connected or not. It should be triggered, if the moving speed is like driving the car." (2026-07-03). Already satisfied by the existing speed/motion verification path — a known vehicle's BT is only ever a same-instant fast path to skip the verification wait, never a precondition.
- **Bluetooth's job is exclusively vehicle identification.** "Bluetooth shall be used for detecting the vehicle — in this way the app can connect trip detection and specific car (private car, business car)." (2026-07-03). This is now true both at trip start (BT fast-path / verification-then-BT-adoption) and mid-trip (`checkVehicleSwitch`'s adopt/switch branches) — see §2 and §3.
- **Fast detection of vehicle switches is a priority** — the user explicitly complained that switching cars silently mis-tracked. This is why the switch-detection debounce (§5, 8s) is short — evaluated far more frequently (every GPS callback) than the old loss-detection debounce ever was, even though that asymmetry no longer has a symmetric counterpart to compare against (loss-of-BT is no longer a concept the trip-end logic cares about at all).

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

This file and its accompanying audit records are the output of following that process across multiple rounds (2026-06-28, 2026-07-03). Keep both updated as the system evolves.

## 9. Meta-lesson from the Phase 12 → Phase 14 reversal

Phase 12's BT-keep-alive policy was not a careless mistake — it was a reasonable-sounding implementation of an explicit, direct user instruction, reviewed twice by independent adversarial agents, and shipped only after both review rounds signed off. It was still wrong, because **no amount of code review catches a false assumption about what a real-world signal actually means** — only field data can. `AudioRoute.isPairedDevicePresent` did exactly what it was designed to do; the design itself assumed that signal meant something it didn't reliably mean.

Takeaways for future rounds:
- **A design surviving adversarial code review is not the same as a design being correct.** Code review catches bugs *in the implementation of a design*; it does not catch a wrong premise shared by the implementer and the reviewer. Only real usage data can catch that.
- **When a user's fix instruction encodes an assumption about hardware/OS behavior** (e.g. "Bluetooth connected means the car is in use"), treat that assumption as provisional, not as settled fact, and say so back to the user if there's a way to verify it empirically rather than just implementing it.
- **When a user reports that a previous fix didn't hold up**, the right response is to re-derive the policy from the new evidence, not to patch the old policy with another special case. Phase 14 replaced Phase 12's mechanism entirely rather than adding a "but not if BT has been connected for more than N hours" exception, because the latter is exactly the kind of ad hoc patch that got the design into trouble in the first place — it treats the symptom, not the wrong premise.
- **Keep this file's design-principle sections (§2, §3, §6) current, not additive.** When a policy is reversed, rewrite the section to state the new policy plainly, and demote the old one to clearly-labeled history (as done in §6 above) rather than leaving both presented as if they coexist.
