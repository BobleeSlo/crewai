# MileLog Tracking Engine — Audit & Fix Record (Phase 15)

**Date:** 2026-07-21
**Scope:** `MileLog/MileLog/TripDetector.swift`, `MileLog/MileLog/NotificationManager.swift`
**Trigger:** User field log `MileLogDetectionLog202607211701.txt` (100 entries, 2026-07-12 → 2026-07-21) — the app had produced no trips at all for a full week, and the user asked to check for "strange connection issues" and why the app was inactive.

---

## Part 1 — Why the app went silent: repeated silent downgrade from "Always" to "While Using"

The log's last three entries are all identical and otherwise unexplained:

```
2026-07-14T13:14:47.611Z  [INFO]  Location authorization changed: whenInUse
2026-07-15T05:27:06.582Z  [INFO]  Location authorization changed: whenInUse
2026-07-20T11:39:27.065Z  [INFO]  Location authorization changed: whenInUse
```

No trip was recorded after 2026-07-14T04:35. **Root cause: background auto-detect requires "Always" location authorization** (`startMonitoringSignificantLocationChanges()` cannot wake a backgrounded/terminated app under "While Using"). Sometime after the last successful trip ended, iOS silently reverted authorization from Always to While Using, and it stayed there for the rest of the week — the three log lines above are just the app re-observing that same degraded state on three separate, unrelated opens, not three separate incidents.

This is not the first occurrence in this same log: earlier, an identical downgrade happened overnight between 2026-07-12 21:13 and 2026-07-13 06:23 (a stale trip-start candidate that had been waiting since 21:13 the previous night finally resolved at 06:23, and the very next log line is `Location authorization changed: whenInUse`). That time, the user apparently noticed and manually re-triggered the upgrade — the log shows `Requested Always authorization` fired twice one second later, and every trip after that point through 07-14 shows `BT connected` / correct background heartbeats, confirming Always was restored. **The second time it happened (after 07-14), nobody was watching for it, so it went uncorrected for a full week.**

Why iOS does this: this matches Apple's documented "background location reminder" — an app holding Always authorization while running mostly in the background (exactly MileLog's whole design) periodically gets a system prompt asking the user to confirm continued background use; if it isn't actively answered, iOS can silently revert to "While Using." This is a platform-level privacy mechanism, not an app bug, and it cannot be suppressed or bypassed — but the app previously had **no way to notice or tell the user it happened**, short of them opening Settings or the Record tab and reading the existing (correct, but entirely passive) permission hint there.

### Fix: proactive alert on downgrade

`TripDetector.locationManagerDidChangeAuthorization` now compares the previous and new authorization state. If it was `.authorizedAlways` and drops to anything else while auto-detect is enabled, it immediately:
- logs a `.warning`-level line making the consequence explicit ("Auto-detect background tracking has stopped..."),
- sends a local push notification (`NotificationManager.sendPermissionDowngradedNotification()`) telling the user auto-detect has stopped and to fix it in Settings.

This won't prevent iOS from downgrading the permission (nothing can), but it closes the actual gap: the user finds out within seconds instead of after a week of silently missing trips.

**Action needed now:** authorization is very likely still "While Using" on your phone as of this log. After installing this fix, open the app once and re-grant Always (Settings tab → "Grant location permission" button, or toggle Auto-detect off/on) — the fix only prevents the *next* silent downgrade from going unnoticed, it doesn't retroactively restore the permission that's already dropped.

## Part 2 — "Strange connection" observations explained

### BT name-only matching on every trip start — expected, not a bug

Every trip start in this log logs `Vehicle matched by BT name only (no UID match): 'Toyota Touch 2 with Go' → Toyota RAV 4.` This is the wireless-CarPlay UID instability already documented in `TRACKING-KNOWLEDGE-BASE.md` §4 — this particular head unit apparently never presents a stable UID, only ever the name. Since only one active vehicle is registered with that name, the fallback is safe and unambiguous (per the Phase 13 fix, an ambiguous name match across 2+ vehicles would instead refuse and log an `.error`). Not an issue unless a second vehicle is ever added with a similarly generic Bluetooth name.

### A 0.9 km trip that took 4h47m to formally close — explained, and fixed

The first trip in the log (`16:26:15` → `21:13:41`) genuinely only drove ~22 seconds past its own start before stopping for good, but wasn't formally closed out until **4 hours 47 minutes later**. Tracing it: the trip's own verification/candidate cycle and the very next trip's candidate both show the identical pattern — a `Timer` (verification deadline or audit tick) doesn't fire at all while the phone is genuinely stationary and the app is fully suspended by iOS, and if literally zero GPS updates arrive in the meantime either (true stillness — no significant location change possible with zero displacement), **nothing runs at all** until the app gets some other execution opportunity — here, the next real drive's significant-location-change wake, nearly 5 hours later.

This is the same iOS background-execution constraint already documented (`TRACKING-KNOWLEDGE-BASE.md` §4), just observed at a much longer gap (hours, not minutes) than previously seen. The stationary-timeout *decision* itself was computed correctly once the audit finally ran (282 minutes since the true last movement, correctly ≥ the 5-minute timeout, correctly not overridden by CoreMotion since its last automotive reading was equally many hours stale) — but the trip's **recorded `endedAt` was stamped at `Date()`**, i.e., whenever the audit finally got to run, not when the car actually stopped. That turned a real ~22-second parking maneuver into a trip record that displays as having lasted almost 5 hours.

**Fix:** `endTrip(reason:at:)` now takes the true end instant as a parameter. The stationary-timeout call site in `auditActiveTrip()` passes `trip.lastMovementAt` — the last confirmed-movement timestamp — instead of defaulting to "now." Force-stop, vehicle-switch, and disable-by-user endings are unaffected (those really are events happening at call time, so `Date()` remains correct there). This does not change any trip's distance or classification, only makes `endedAt`/duration accurate to when the car actually stopped, which matters for day-based logbook rules.

## What to verify next

1. **Re-grant "Always" location permission** on the phone right away (see Part 1) — this log ends with it still degraded.
2. **After a future long-stationary gap** (car parked for hours with the phone left inside, or genuinely at rest), confirm the eventual trip record's duration looks reasonable (ends shortly after the last real movement) rather than spanning the full gap until the next drive.
3. **Force a permission downgrade in iOS Settings** (Settings → Privacy → Location Services → MileLog → "While Using the App") while auto-detect is on, and confirm a push notification arrives immediately rather than the app going silent unnoticed.
