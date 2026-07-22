import Foundation
import CoreLocation
import AVFoundation
import Combine

/// In-progress auto trip kept on disk so it survives the app being killed.
struct ActiveTripState: Codable {
    var id: UUID
    var vehicleID: UUID
    var audioDeviceUID: String?
    /// Display name of the paired BT device (used to re-confirm presence even
    /// when the audio UID briefly changes, e.g. CarPlay route reshuffles).
    var audioDeviceName: String?
    var startedAt: Date
    var startLat: Double
    var startLng: Double
    var lastLat: Double
    var lastLng: Double
    var distanceKm: Double
    var lastMovementAt: Date
    /// Most recent GPS speed in km/h — logged for diagnostics only.
    var lastSpeedKmh: Double = 0
    var points: [RecordedPoint] = []
}

struct RecordedPoint: Codable {
    var recordedAt: Date
    var lat: Double
    var lng: Double
    var speedKmh: Float
    var accuracyM: Float
}

/// Auto-detect engine: wakes on significant location changes, verifies real
/// driving via speed/motion (regardless of Bluetooth), tracks the drive with
/// active GPS, ends the trip purely on elapsed time since genuine movement,
/// then saves + notifies.
///
/// Bluetooth's ONLY job in this design is vehicle IDENTIFICATION — which car
/// (private vs. business) a trip should be attributed to. It never decides
/// whether a trip is still happening. An earlier design kept a trip alive
/// indefinitely as long as the paired car's Bluetooth read as "connected";
/// field data showed car head units routinely stay Bluetooth-connected for
/// HOURS after the engine is off and the driver has left, which turned one
/// day's driving into a single 131 km, ~19-hour "trip" that never ended on
/// its own. Trip lifetime is now governed solely by movement.
///
/// Lifecycle is driven by:
///   1. CLLocationManager significant-location changes  (app wake)
///   2. Speed/CoreMotion verification                    (real drive vs. walk/run)
///   3. Active GPS updates while a trip is running        (distance + movement time)
///   4. AVAudioSession route-change notifications         (vehicle identification only)
@MainActor
final class TripDetector: NSObject, ObservableObject {

    @Published private(set) var isEnabled = false
    @Published private(set) var activeTrip: ActiveTripState?
    @Published private(set) var permission: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let motion = MotionVerifier()
    private unowned let store: Store
    private unowned let log: DetectionLog
    private weak var notifications: NotificationManager?
    /// Set by MileLogApp so the detector can refuse to start while the user
    /// is manually recording a trip with the Start/Stop button.
    weak var manualLocationManager: LocationManager?

    private let activeTripURL: URL
    /// Recurring sanity check during a trip — fires every `auditIntervalSeconds`
    /// and re-evaluates the pure elapsed-time-since-movement end condition.
    /// Logs each tick so the Detection log shows why a trip did or didn't end.
    private var auditTimer: Timer?
    private let auditIntervalSeconds: TimeInterval = 60

    // Verification (candidate-trip) state — before we commit to a real Trip
    // we wait for either a sustained driving speed or CoreMotion's
    // "automotive" signal combined with GPS movement, otherwise the wake
    // was just a walk / run.
    private struct Candidate {
        let startedAt: Date
        let startLocation: CLLocation
        var lastLocation: CLLocation
        var maxSpeedKmh: Double
        var distanceMetres: Double
        let confirmedByBluetooth: Bool
    }
    private var candidate: Candidate?
    private var verificationDeadline: Timer?
    private let speedConfirmKmh: Double = 25
    private let verificationSeconds: TimeInterval = 90
    /// CoreMotion's "automotive" signal alone is unreliable when the user is
    /// in a moving vehicle as a passenger or even walking next to a car.
    /// Require this much GPS movement during the window before trusting it.
    private let automotiveMovementMetres: Double = 100

    // Duplicate-audit suppression — the audit can occasionally fire twice
    // in rapid succession when an audio route change handler triggers a
    // re-check alongside the timer. Anything within this window is dropped.
    private var lastAuditAt: Date = .distantPast
    private let auditDedupeWindow: TimeInterval = 5

    // GPS health diagnostics so a future "GPS interrupted" complaint
    // becomes obvious in the Detection log.
    private var lastLocationAt: Date = .distantPast
    private var lastAccuracy: Double = -1

    // Trip-end policy: PURE movement-based, no Bluetooth involvement at all.
    // A trip ends when `stationaryTimeoutMinutes` (Settings, default 5) have
    // elapsed since the last genuine movement — full stop, no override. This
    // naturally tolerates brief real-world stops (a red light is rarely more
    // than a minute or two) without needing any "keep alive" exception, and
    // it can no longer be extended indefinitely by a lingering Bluetooth
    // connection the way the previous design could.
    //   - movingSpeedKmh: at/above this the car counts as "moving" and
    //     `lastMovementAt` is refreshed.
    private let movingSpeedKmh: Double = 3

    // GPS-blackout protection: a tunnel, underground garage, or a plain
    // background-execution gap (iOS can suspend the app for minutes at a
    // time even while driving — see TRACKING-KNOWLEDGE-BASE.md §4) stops
    // location callbacks from arriving at all, which looks IDENTICAL to a
    // genuine stop from `lastMovementAt` alone (adversarial review of Phase
    // 14 confirmed this: CLLocationManager doesn't fire updates while
    // genuinely stationary either, so "no updates" cannot by itself mean
    // "the car stopped"). CoreMotion's accelerometer-based "automotive"
    // classification doesn't need GPS or Bluetooth, so it's used as a
    // second, independent movement signal purely to avoid ending a trip on
    // GPS silence alone — this is still movement evidence, not Bluetooth,
    // so it doesn't violate the "BT is identification-only" rule.
    //   - motionSignalFreshnessSeconds: how recent CoreMotion's last
    //     automotive reading must be to still count as "currently driving."
    //   - gpsBlackoutOverrideCapMinutes: absolute bound — even with
    //     CoreMotion still reporting automotive, a trip stationary-by-GPS
    //     for longer than this ends anyway, so a stuck/misclassifying
    //     sensor can't keep a trip open forever.
    private let motionSignalFreshnessSeconds: TimeInterval = 120
    private let gpsBlackoutOverrideCapMinutes: Double = 45

    // Vehicle-switch debounce: require the newly-detected vehicle's BT to be
    // observed consistently for this long before actually switching (i.e.
    // reassigning which vehicle the in-progress trip belongs to), so a
    // one-off BLE proximity flicker (e.g. briefly picking up a nearby parked
    // car's signal) can't misattribute a real drive. Checked on every GPS
    // update and every route-change event, so a short wall-clock window is
    // used rather than a tick counter.
    private var pendingSwitchVehicleID: UUID?
    private var pendingSwitchFirstSeenAt: Date?
    private let switchConfirmSeconds: TimeInterval = 8

    // Active-trip persistence throttle: JSON-encoding + rewriting the whole
    // active-trip file on every single GPS callback (which can arrive every
    // few metres on a long drive) is real I/O cost that risks delaying the
    // very callback processing this detector depends on. State-transition
    // moments (trip start, switch, merge) force an immediate write; routine
    // in-trip updates are throttled.
    private var lastPersistAt: Date = .distantPast
    private let persistThrottleSeconds: TimeInterval = 3

    // Trip-merge tolerances: a new trip that starts within this much time
    // AND distance of the previous trip's end is treated as a continuation
    // of that trip instead of a separate row.
    private let mergeWindowMinutes: Double = 15
    private let mergeRadiusMetres: Double = 300

    /// Set only when `auditActiveTrip()` closes a trip on its FIRST pass
    /// after an app relaunch (`restoreActiveTripIfAny`'s immediate audit),
    /// never on a normal, continuously-running 60s tick. This distinction
    /// matters: a normal tick closing a trip means the app was RUNNING and
    /// genuinely observed no movement for the full timeout — trustworthy
    /// evidence of a real stop. A post-relaunch closure means the app was
    /// DEAD for however long the gap was and has no idea whether the car
    /// kept moving the whole time — confirmed in the field (2026-07-22 log)
    /// as happening repeatedly, with gaps of 23–61+ minutes, during what
    /// the user reported was one continuous highway drive with Bluetooth
    /// connected throughout. The normal merge tolerances (15 min / 300 m)
    /// exist to avoid stitching together genuinely separate drives, and are
    /// far too tight for a gap this size at highway speed — so this context
    /// lets the very next trip for the SAME vehicle reclaim the interrupted
    /// one directly, bypassing both limits, since same-vehicle-immediately-
    /// after is itself strong evidence of a continuation rather than a
    /// coincidence. See TRACKING-AUDIT-2026-07-22.md.
    private var relaunchRecoveryContext: (tripID: UUID, vehicleID: UUID, endedAt: Date)?
    /// Bounded well above the worst confirmed app-kill-during-driving gap
    /// seen so far (61 min), but deliberately NOT extremely generous: this
    /// reclaim can't tell "the app died mid-drive" apart from "the app died
    /// while the car was ALSO genuinely parked for a while, then much later
    /// a separate, unrelated trip begins" — too wide a window risks merging
    /// two real, distinct trips into one and back-dating the second one.
    private let relaunchRecoveryWindowMinutes: Double = 90

    init(store: Store, log: DetectionLog, notifications: NotificationManager) {
        self.store = store
        self.log = log
        self.notifications = notifications

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        activeTripURL = dir.appendingPathComponent("active-trip.json")

        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        // Battery / accuracy trade-off is owned by UserSettings.energyMode —
        // apply the current preset here, and re-apply on every trip start
        // so changes from Settings take effect immediately.
        store.settings.energyMode.apply(to: manager)
        permission = manager.authorizationStatus

        restoreActiveTripIfAny()

        if store.settings.autoDetectEnabled && permission == .authorizedAlways {
            startMonitoring()
        }
    }

    // MARK: - Public API

    /// Single entry point for the Auto-detect toggle, used by both the Record
    /// screen quick-toggle and the Settings toggle so there's exactly one
    /// code path (persist the preference, request notification permission +
    /// location when turning on, tear down when turning off).
    func setAutoDetect(_ enabled: Bool) {
        store.settings.autoDetectEnabled = enabled
        store.save()
        Task {
            if enabled {
                if let notifications { _ = await notifications.requestPermission() }
                await requestEnable()
            } else {
                disable()
            }
        }
    }

    /// Called when the user flips the Auto-detect toggle on.
    func requestEnable() async {
        switch permission {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // After granting "When in Use", the user can come back and tap again to upgrade.
            log.log("Requested When-in-Use; tap again after granting to request Always.", level: .info)
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            log.log("Requested Always authorization.", level: .info)
        case .authorizedAlways:
            startMonitoring()
        case .denied, .restricted:
            log.log("Location permission denied. Enable 'Always' in iOS Settings.", level: .warning)
        @unknown default:
            break
        }
    }

    func disable() {
        stopMonitoring()
        if activeTrip != nil { endTrip(reason: "disabled by user") }
        relaunchRecoveryContext = nil
    }

    /// User-initiated stop from the Record-tab banner. Records the elapsed
    /// stationary time (the sole reason auto-stop should or shouldn't have
    /// fired) plus BT status for identification context, so the Detection
    /// log captures the post-mortem.
    func forceEndTrip() {
        guard let trip = activeTrip else {
            log.log("Force-stop tapped but no active trip.", level: .warning)
            return
        }
        let stationaryMin = Date().timeIntervalSince(trip.lastMovementAt) / 60
        let currentBT = AudioRoute.currentBluetoothOutput()
        let btStatus: String
        if let pairedUID = trip.audioDeviceUID {
            if currentBT?.uid == pairedUID {
                btStatus = "BT still connected (\(currentBT?.name ?? "?"))"
            } else if let cur = currentBT {
                btStatus = "BT changed to \(cur.name)"
            } else {
                btStatus = "BT disconnected"
            }
        } else {
            btStatus = "no BT pairing"
        }
        log.log(String(format: "FORCE-STOP: %.1f km, %d min since last movement, %@",
                       trip.distanceKm, Int(stationaryMin), btStatus),
                level: .warning)
        endTrip(reason: "force-stopped by user")
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard !isEnabled else { return }
        manager.startMonitoringSignificantLocationChanges()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        isEnabled = true
        log.log("Auto-detect ON.", level: .info)
    }

    private func stopMonitoring() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        motion.stop()
        verificationDeadline?.invalidate()
        verificationDeadline = nil
        candidate = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        isEnabled = false
        log.log("Auto-detect OFF.", level: .info)
    }

    // MARK: - Trip start (with candidate/verification phase)

    private func handleSignificantLocation(_ location: CLLocation) {
        log.log(String(format: "Significant change @ %.4f,%.4f",
                       location.coordinate.latitude, location.coordinate.longitude))

        // Hard guards — never run two trips at the same time.
        if activeTrip != nil {
            log.log("Skipped: trip already active.")
            return
        }
        if candidate != nil {
            log.log("Skipped: candidate already pending verification.")
            return
        }
        if let manual = manualLocationManager, manual.isTracking {
            log.log("Skipped: manual recording is in progress.", level: .warning)
            return
        }

        let device = AudioRoute.currentBluetoothOutput()
        let knownVehicle = matchVehicle(for: device)

        // Fast path: if the phone is already connected to a known car's
        // Bluetooth, that's high-confidence — start the trip immediately.
        if let vehicle = knownVehicle {
            commitTripStart(at: location, startedAt: Date(),
                            vehicle: vehicle, device: device)
            return
        }

        // Slow path: no BT match. Enter verification — gather speed + CoreMotion
        // for up to `verificationSeconds`. Only then decide if this is really a drive.
        beginVerification(at: location)
    }

    private func beginVerification(at location: CLLocation) {
        candidate = Candidate(
            startedAt: Date(),
            startLocation: location,
            lastLocation: location,
            maxSpeedKmh: 0,
            distanceMetres: 0,
            confirmedByBluetooth: false
        )
        persistCandidate()
        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        if motion.isAvailable {
            motion.start()
        } else {
            log.log("Motion API unavailable (missing NSMotionUsageDescription?); falling back to speed-only verification.", level: .warning)
        }

        verificationDeadline?.invalidate()
        verificationDeadline = Timer.scheduledTimer(withTimeInterval: verificationSeconds,
                                                    repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishVerification() }
        }
        log.log("Verification started — need speed > \(Int(speedConfirmKmh)) km/h, or automotive activity with GPS movement.")
    }

    /// Called on every active-GPS update while in candidate mode.
    private func updateVerification(with location: CLLocation) {
        guard var c = candidate else { return }

        // Wall-clock timeout — Timer.scheduledTimer doesn't fire while iOS
        // suspends the app, so the 90s deadline can stretch to many minutes.
        // Whenever an update lands we also check elapsed time and finish if
        // the window has passed.
        if Date().timeIntervalSince(c.startedAt) >= verificationSeconds {
            finishVerification(early: false)
            return
        }

        let kmh = max(0, location.speed) * 3.6
        if kmh > c.maxSpeedKmh { c.maxSpeedKmh = kmh }

        // Accumulate GPS distance from the last update so the automotive
        // confirmation can require real movement (a phone in a stationary
        // car next to a passing vehicle can confuse CoreMotion alone).
        let metres = location.distance(from: c.lastLocation)
        if metres > 5 {
            c.distanceMetres += metres
            c.lastLocation = location
        }
        candidate = c

        let automotiveConfirmed = motion.hasAutomotiveSignal && c.distanceMetres > automotiveMovementMetres
        if kmh > speedConfirmKmh || automotiveConfirmed {
            finishVerification(early: true)
        }
    }

    private func finishVerification(early: Bool = false) {
        guard let c = candidate else { return }
        verificationDeadline?.invalidate()
        verificationDeadline = nil

        let speedOK = c.maxSpeedKmh > speedConfirmKmh
        let autoOK  = motion.hasAutomotiveSignal
        let movementOK = c.distanceMetres > automotiveMovementMetres
        let nonCar = motion.hasNonAutomotiveSignal
        let walkingDetected = nonCar && !autoOK

        // PASS when either the speed clearly indicates driving, OR
        // CoreMotion calls it automotive AND we covered enough GPS distance
        // to disqualify "passenger / sat near a moving car" false positives.
        let pass = !walkingDetected && (speedOK || (autoOK && movementOK))

        if pass {
            log.log(String(format: "Verification PASSED (%@): max %.1f km/h, distance %.0f m, automotive=%@, non-car=%@",
                           early ? "early" : "timeout",
                           c.maxSpeedKmh,
                           c.distanceMetres,
                           autoOK ? "yes" : "no",
                           nonCar ? "yes" : "no"), level: .info)
            candidate = nil
            clearPersistedCandidate()
            // Deliberately NOT calling motion.stop() here — CoreMotion keeps
            // running for the trip's full duration now (see commitTripStart),
            // so its accelerometer-based "automotive" signal stays available
            // as a GPS-independent movement check throughout the drive, not
            // just during this verification window.
            // Re-read BT now (it may have connected while we were verifying).
            let device = AudioRoute.currentBluetoothOutput()
            let vehicle = matchVehicle(for: device) ?? fallbackVehicle()
            guard let vehicle else { return }
            commitTripStart(at: c.startLocation, startedAt: c.startedAt,
                            vehicle: vehicle, device: device)
        } else {
            log.log(String(format: "Verification FAILED: max %.1f km/h, distance %.0f m, automotive=%@, non-car=%@ — discarding.",
                           c.maxSpeedKmh,
                           c.distanceMetres,
                           autoOK ? "yes" : "no",
                           nonCar ? "yes" : "no"), level: .info)
            candidate = nil
            clearPersistedCandidate()
            motion.stop()
            manager.stopUpdatingLocation()
        }
    }

    private func commitTripStart(at location: CLLocation, startedAt: Date,
                                 vehicle: Vehicle, device: BluetoothAudioDevice?,
                                 allowMerge: Bool = true) {
        // Keep CoreMotion running for the whole trip (idempotent — a no-op
        // if verification already started it). The BT fast-path in
        // handleSignificantLocation skips verification entirely, so this is
        // the only place guaranteed to run for every trip start.
        if motion.isAvailable { motion.start() }

        // Trip merge: if this matches a continuation of the previous trip
        // (same vehicle, within mergeWindow minutes and mergeRadius metres
        // of the previous end coords), resume that trip instead of splitting
        // a real drive into multiple rows because of a brief stop.
        // Disabled (allowMerge: false) when this start is the result of a
        // detected vehicle switch — see checkVehicleSwitch's doc comment.
        if allowMerge, tryMergeWithRecentTrip(at: location, vehicle: vehicle, device: device) {
            return
        }

        let state = ActiveTripState(
            id: UUID(),
            vehicleID: vehicle.id,
            audioDeviceUID: device?.uid,
            audioDeviceName: device?.name,
            startedAt: startedAt,
            startLat: location.coordinate.latitude,
            startLng: location.coordinate.longitude,
            lastLat: location.coordinate.latitude,
            lastLng: location.coordinate.longitude,
            distanceKm: 0,
            lastMovementAt: Date(),
            lastSpeedKmh: max(0, location.speed) * 3.6,
            points: [RecordedPoint(
                recordedAt: location.timestamp,
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speedKmh: Float(max(0, location.speed) * 3.6),
                accuracyM: Float(location.horizontalAccuracy)
            )]
        )
        activeTrip = state
        persistActiveTrip(force: true)
        pendingSwitchVehicleID = nil
        pendingSwitchFirstSeenAt = nil

        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        startAuditTimer()

        let bt = device.map { "BT \($0.name)" } ?? "no BT"
        log.log("Trip started: \(vehicle.name) [\(bt)] · \(store.settings.energyMode.label)", level: .info)
    }

    // MARK: - Audit (pure elapsed-time-since-movement trip end)

    private func startAuditTimer() {
        auditTimer?.invalidate()
        // The Timer fires on the current run loop; we don't capture self in
        // the outer closure (no reference) — the inner Task captures self
        // explicitly weak, which silences the Swift 6 'captured var self'
        // warning that would fire on an implicit self.
        auditTimer = Timer.scheduledTimer(withTimeInterval: auditIntervalSeconds,
                                          repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.auditActiveTrip()
            }
        }
    }

    private func stopAuditTimer() {
        auditTimer?.invalidate()
        auditTimer = nil
    }

    /// Runs every `auditIntervalSeconds` (and on each wake, and immediately
    /// after restoring a trip on relaunch). Trip-end decision is PURE
    /// elapsed-time-since-movement — no Bluetooth involvement. See the class
    /// doc comment for why: a prior design that kept trips alive as long as
    /// Bluetooth read "connected" let a single day's driving run as one
    /// 131 km, ~19-hour trip that never ended on its own, because car head
    /// units routinely stay Bluetooth-connected long after the engine is
    /// off. Bluetooth is checked here ONLY for vehicle identification via
    /// checkVehicleSwitch(), never as a reason to keep the trip open.
    /// `isPostRelaunch` is true only for the one immediate call made right
    /// after `restoreActiveTripIfAny()` resumes a persisted trip — see
    /// `relaunchRecoveryContext`'s doc comment for why a stationary-timeout
    /// ending needs to be treated differently when it happens here versus
    /// on a normal, continuously-running 60s tick.
    private func auditActiveTrip(isPostRelaunch: Bool = false) {
        guard let trip = activeTrip else {
            stopAuditTimer()
            return
        }

        // Duplicate-call suppression — a route-change handler can nudge the
        // audit just after the 60s timer fires.
        if Date().timeIntervalSince(lastAuditAt) < auditDedupeWindow { return }
        lastAuditAt = Date()

        // Vehicle-switch / identification check runs first — purely about
        // WHICH vehicle this trip belongs to, never about whether it's over.
        if checkVehicleSwitch() { return }

        let stationaryMin = Date().timeIntervalSince(trip.lastMovementAt) / 60
        let timeout = Double(store.settings.stationaryTimeoutMinutes)

        if stationaryMin >= timeout {
            // GPS-blackout check: "no location updates" and "genuinely
            // parked" are indistinguishable from GPS timing alone (see the
            // constant's doc comment above). Before ending, ask CoreMotion
            // — an independent, GPS-free movement signal — whether it's
            // seen automotive activity recently. If so, this is very likely
            // a tunnel/dead-zone while still driving, not a real stop.
            if let lastAuto = motion.lastAutomotiveActivityAt,
               Date().timeIntervalSince(lastAuto) < motionSignalFreshnessSeconds,
               stationaryMin < gpsBlackoutOverrideCapMinutes {
                log.log(String(format: "AUDIT: %.0f min stationary by GPS timing, but CoreMotion confirms automotive activity %.0fs ago — likely a GPS dead zone, not ending.",
                               stationaryMin, Date().timeIntervalSince(lastAuto)), level: .info)
            } else {
                log.log(String(format: "AUDIT: ending trip — stationary %.0f min >= %.0f min timeout.",
                               stationaryMin, timeout), level: .info)
                // A post-relaunch closure is unconfirmed — the app was dead
                // for the whole gap, so "stationary" here just means
                // "unobserved," not "genuinely stopped." Remember this trip
                // so the very next same-vehicle start can reclaim it instead
                // of recording it as a real, separate stop.
                if isPostRelaunch {
                    relaunchRecoveryContext = (tripID: trip.id, vehicleID: trip.vehicleID, endedAt: trip.lastMovementAt)
                    log.log("This closure followed an app relaunch, not a live observation — flagged for possible reclaim if driving resumes shortly.",
                            level: .warning)
                }
                // Backdate endedAt to when the car actually stopped, not to
                // whenever this audit finally got to run — see endTrip's doc.
                endTrip(reason: "stationary \(Int(stationaryMin)) min", at: trip.lastMovementAt)
                return
            }
        }

        // --- Heartbeat (velocity + GPS health + BT for diagnostics only) --
        let secsSinceGPS = Int(Date().timeIntervalSince(lastLocationAt))
        let gpsHealth: String
        if lastLocationAt == .distantPast {
            gpsHealth = "GPS none yet"
        } else {
            gpsHealth = String(format: "GPS %ds ago · acc %.0f m", secsSinceGPS, max(0, lastAccuracy))
        }
        let hasPairing = trip.audioDeviceUID != nil || (trip.audioDeviceName?.isEmpty == false)
        let btLabel = hasPairing
            ? (AudioRoute.isPairedDevicePresent(uid: trip.audioDeviceUID, name: trip.audioDeviceName) ? "connected" : "not connected")
            : "none"
        let motionLabel: String
        if let lastAuto = motion.lastAutomotiveActivityAt {
            motionLabel = String(format: "automotive %.0fs ago", Date().timeIntervalSince(lastAuto))
        } else {
            motionLabel = "no signal yet"
        }
        log.log(String(format: "AUDIT heartbeat: %.1f km · v %.0f km/h · %.0f min since movement (ends at %.0f) · BT %@ · motion %@ · %@",
                       trip.distanceKm,
                       trip.lastSpeedKmh,
                       stationaryMin,
                       timeout,
                       btLabel,
                       motionLabel,
                       gpsHealth))
    }

    /// Resume the previous trip instead of starting a fresh one when the
    /// new wake-up looks like a continuation (same vehicle, within
    /// `mergeWindowMinutes` minutes and `mergeRadiusMetres` metres of the
    /// previous end). Prevents a real 50-km work day from being recorded as
    /// 6 fragments because of brief stops (lunch, fuel, customer visit).
    /// Returns true if a merge happened (caller skips the normal start path).
    private func tryMergeWithRecentTrip(at location: CLLocation,
                                        vehicle: Vehicle,
                                        device: BluetoothAudioDevice?) -> Bool {
        // Relaunch-recovery fast path — see the property's doc comment.
        // Bypasses the normal time/distance tolerances entirely, because
        // those exist to avoid stitching together genuinely separate
        // drives, and this isn't that: it's the SAME vehicle starting again
        // immediately after a trip we know was only closed because the app
        // itself lost execution, not because anyone observed a real stop.
        if let ctx = relaunchRecoveryContext,
           ctx.vehicleID == vehicle.id,
           Date().timeIntervalSince(ctx.endedAt) < relaunchRecoveryWindowMinutes * 60,
           let lastTrip = store.trips.first(where: { $0.id == ctx.tripID }),
           // Same intervening-vehicle guard as the normal merge path below —
           // if a different vehicle was genuinely driven in between, this
           // isn't a continuation, it's a real return to vehicle A later.
           !store.trips.contains(where: { $0.vehicleID != vehicle.id && $0.startedAt > ctx.endedAt }) {
            relaunchRecoveryContext = nil
            log.log(String(format: "Reclaiming trip interrupted by app relaunch (gap %.0f min) — continuing rather than starting fresh.",
                           Date().timeIntervalSince(ctx.endedAt) / 60), level: .info)
            resumeTrip(lastTrip, at: location, vehicle: vehicle, device: device)
            return true
        }

        guard let lastTrip = store.trips
            .filter({ $0.vehicleID == vehicle.id && !$0.isLocked })
            .max(by: { $0.endedAt < $1.endedAt })
        else { return false }

        let minutesSinceLast = Date().timeIntervalSince(lastTrip.endedAt) / 60
        guard minutesSinceLast < mergeWindowMinutes else { return false }

        // Refuse to merge if a DIFFERENT vehicle's trip started after this
        // one ended — that means the vehicle was switched away and back (an
        // A→B→A bounce). Merging would silently back-date the resumed A
        // trip's start time across the B interlude, mis-representing when A
        // was actually being driven again. Disabling merge only at the
        // switch-triggered trip's OWN start (checkVehicleSwitch's
        // allowMerge: false) isn't enough on its own — that trip's later,
        // NORMAL end can still merge FORWARD into this pre-switch trip once
        // it ends, which is exactly the gap this check closes. Scoped
        // automatically to roughly the merge window since lastTrip.endedAt
        // is already known to be within mergeWindowMinutes of now.
        if let interveningTrip = store.trips.first(where: {
            $0.vehicleID != vehicle.id && $0.startedAt > lastTrip.endedAt
        }) {
            log.log("Merge skipped: \(store.vehicleName(interveningTrip.vehicleID)) was driven after this trip ended — avoiding a cross-vehicle merge that would back-date the resumed trip.",
                    level: .info)
            return false
        }

        guard let endLat = lastTrip.endLat, let endLng = lastTrip.endLng else { return false }
        let prevEnd = CLLocation(latitude: endLat, longitude: endLng)
        let distance = prevEnd.distance(from: location)
        guard distance < mergeRadiusMetres else { return false }

        log.log(String(format: "Merging into recent trip (gap %.0f min, %.0f m). Keeping start time %@.",
                       minutesSinceLast, distance,
                       lastTrip.startedAt.formatted(date: .omitted, time: .shortened)),
                level: .info)

        resumeTrip(lastTrip, at: location, vehicle: vehicle, device: device)
        return true
    }

    /// Pulls a saved trip back out of `store.trips` and resurrects it as the
    /// active in-progress trip. Shared by the normal brief-stop merge and
    /// the relaunch-recovery fast path above — both end with the exact same
    /// resurrection, just reached via different tolerance checks.
    private func resumeTrip(_ lastTrip: Trip, at location: CLLocation,
                            vehicle: Vehicle, device: BluetoothAudioDevice?) {
        store.trips.removeAll { $0.id == lastTrip.id }
        store.save()
        if let supabase = store.supabaseService {
            let id = lastTrip.id
            Task { try? await supabase.deleteTrip(id: id) }
        }

        // Restore the ORIGINAL trip's start point, not the pause location.
        // Getting this wrong silently corrupts TripClassifier's home/work
        // proximity check and the reverse-geocoded start address for every
        // merged trip — confirmed by adversarial review. Falls back to
        // endLat/endLng only for a trip saved before startLat/startLng
        // existed on the model.
        let originLat = lastTrip.startLat ?? lastTrip.endLat ?? location.coordinate.latitude
        let originLng = lastTrip.startLng ?? lastTrip.endLng ?? location.coordinate.longitude

        let resumed = ActiveTripState(
            id: lastTrip.id,                                       // keep id for any external refs
            vehicleID: vehicle.id,
            audioDeviceUID: device?.uid,
            audioDeviceName: device?.name,
            startedAt: lastTrip.startedAt,                          // keep original start time
            startLat: originLat,
            startLng: originLng,
            lastLat: location.coordinate.latitude,
            lastLng: location.coordinate.longitude,
            distanceKm: lastTrip.distanceKm,                        // carry forward accumulated km
            lastMovementAt: Date(),
            lastSpeedKmh: max(0, location.speed) * 3.6,
            points: [RecordedPoint(
                recordedAt: location.timestamp,
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speedKmh: Float(max(0, location.speed) * 3.6),
                accuracyM: Float(location.horizontalAccuracy)
            )]
        )
        activeTrip = resumed
        persistActiveTrip(force: true)
        pendingSwitchVehicleID = nil
        pendingSwitchFirstSeenAt = nil

        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        startAuditTimer()
    }

    /// When no BT match is available, prefer the vehicle from the user's most
    /// recent trip instead of arbitrarily picking the first one in the list.
    /// Skips archived vehicles — an archived vehicle should never be silently
    /// reused as the fallback for a brand-new trip.
    private func fallbackVehicle() -> Vehicle? {
        if let latest = store.trips.sorted(by: { $0.startedAt > $1.startedAt }).first,
           let v = store.vehicle(latest.vehicleID), v.isActive {
            return v
        }
        return store.activeVehicles.first ?? store.vehicles.first
    }

    /// Only matches against active (non-archived) vehicles — an archived
    /// vehicle's stale Bluetooth pairing must not silently claim trips.
    ///
    /// Matching strategy, most to least confident:
    ///   1. Exact UID match — unique per physical BT device, so this is
    ///      trusted unconditionally.
    ///   2. Name match, ONLY if it uniquely identifies a single active
    ///      vehicle. Many head units report a generic name ("CarPlay",
    ///      "Car Multimedia") rather than something car-specific — this
    ///      app's own field data shows more than one vehicle pairing as
    ///      plain "CarPlay". If the connecting device's name matches more
    ///      than one registered vehicle, guessing which one is exactly the
    ///      kind of silent mis-attribution this app exists to prevent, so
    ///      we refuse and log an error asking the user to re-pair instead.
    private func matchVehicle(for device: BluetoothAudioDevice?) -> Vehicle? {
        guard let device else { return nil }
        let pool = store.activeVehicles

        if let v = pool.first(where: { !$0.bluetoothUID.isEmpty && $0.bluetoothUID == device.uid }) {
            return v
        }

        let nameMatches = pool.filter { !$0.bluetoothName.isEmpty && $0.bluetoothName == device.name }
        if nameMatches.count == 1 {
            log.log("Vehicle matched by BT name only (no UID match): '\(device.name)' → \(nameMatches[0].name).",
                    level: .warning)
            return nameMatches[0]
        }
        if nameMatches.count > 1 {
            log.log("AMBIGUOUS BT name '\(device.name)' matches \(nameMatches.count) active vehicles (\(nameMatches.map(\.name).joined(separator: ", "))) — refusing to guess. Re-pair each vehicle from its own Bluetooth connection so their IDs are unique.",
                    level: .error)
        }
        return nil
    }

    /// Bluetooth's identification duty for an already-active trip: detects
    /// either (a) a DIFFERENT known vehicle's Bluetooth connecting — e.g.
    /// the user parked car A, walked into car B, and car B's paired BT
    /// connected — or (b) the trip's OWN already-assigned vehicle's
    /// Bluetooth becoming available after the trip started without it (the
    /// common case for a trip that began via pure speed/motion verification
    /// before Bluetooth finished pairing). This function only ever changes
    /// or confirms WHICH vehicle the trip belongs to — it never ends a trip
    /// for any reason other than a genuine switch, and never keeps one open.
    ///
    /// Switch detection requires the new vehicle's BT to be seen
    /// consistently for `switchConfirmSeconds` before acting (see debounce
    /// comment above) — adversarial review found that a single-read trigger
    /// here could fragment a real drive on a one-off BLE proximity flicker.
    ///
    /// On a confirmed switch: ends the current trip immediately (using its
    /// last known point as the transition point) and starts a fresh one for
    /// the newly-detected vehicle, WITHOUT allowing that new trip to merge
    /// into an older saved trip (a detected switch is by definition a
    /// discontinuous event — resurrecting an unrelated earlier trip would
    /// misattribute distance and back-date its start time). Returns true if
    /// it acted, so callers can bail out of whatever they were doing with
    /// the now-stale trip reference.
    @discardableResult
    private func checkVehicleSwitch() -> Bool {
        guard var trip = activeTrip else { return false }
        guard let currentDevice = AudioRoute.currentBluetoothOutput() else {
            pendingSwitchVehicleID = nil
            pendingSwitchFirstSeenAt = nil
            return false
        }

        let matchesCurrentPairing =
            (trip.audioDeviceUID != nil && !trip.audioDeviceUID!.isEmpty && currentDevice.uid == trip.audioDeviceUID) ||
            (trip.audioDeviceName != nil && !trip.audioDeviceName!.isEmpty && currentDevice.name == trip.audioDeviceName)
        guard !matchesCurrentPairing else {
            pendingSwitchVehicleID = nil
            pendingSwitchFirstSeenAt = nil
            return false
        }

        guard let newVehicle = matchVehicle(for: currentDevice) else {
            pendingSwitchVehicleID = nil
            pendingSwitchFirstSeenAt = nil
            return false
        }

        if newVehicle.id == trip.vehicleID {
            // Not a switch — Bluetooth is confirming the vehicle we already
            // assigned (typically a trip that started via motion-only
            // verification before BT finished pairing). Adopt the pairing
            // onto the trip immediately, no debounce needed since we're not
            // changing anything about the trip's classification or lifetime.
            // No forced disk write either — this is diagnostic/identification
            // metadata, not a state transition, so the routine 3s persist
            // throttle is fine (adversarial review flagged an unthrottled
            // write here as unnecessary given a UID that briefly flip-flops
            // could otherwise force a write on every occurrence).
            if trip.audioDeviceUID != currentDevice.uid || trip.audioDeviceName != currentDevice.name {
                trip.audioDeviceUID = currentDevice.uid
                trip.audioDeviceName = currentDevice.name
                activeTrip = trip
                persistActiveTrip()
                log.log("Vehicle confirmed via Bluetooth: \(newVehicle.name) ('\(currentDevice.name)').", level: .info)
            }
            pendingSwitchVehicleID = nil
            pendingSwitchFirstSeenAt = nil
            return false
        }

        if pendingSwitchVehicleID == newVehicle.id, let firstSeen = pendingSwitchFirstSeenAt {
            guard Date().timeIntervalSince(firstSeen) >= switchConfirmSeconds else { return false }
        } else {
            pendingSwitchVehicleID = newVehicle.id
            pendingSwitchFirstSeenAt = Date()
            log.log("Possible vehicle switch to \(newVehicle.name) via BT '\(currentDevice.name)' — confirming over \(Int(switchConfirmSeconds))s before acting.",
                    level: .info)
            return false
        }

        log.log("VEHICLE SWITCH confirmed: BT changed from '\(trip.audioDeviceName ?? "none")' to '\(currentDevice.name)' (\(newVehicle.name)). Ending current trip and starting a new one.",
                level: .warning)

        pendingSwitchVehicleID = nil
        pendingSwitchFirstSeenAt = nil

        let switchLocation = CLLocation(latitude: trip.lastLat, longitude: trip.lastLng)
        endTrip(reason: "vehicle switched to \(newVehicle.name)")
        commitTripStart(at: switchLocation, startedAt: Date(), vehicle: newVehicle,
                        device: currentDevice, allowMerge: false)
        return true
    }

    // MARK: - Trip progress

    private func updateActiveTrip(with location: CLLocation) {
        // Vehicle-switch check runs on every location update too (not just
        // the 60s audit tick) — AVAudioSession route changes are usually
        // near-instant, but this is a cheap, redundant safety net given how
        // costly a mis-attributed trip is (it feeds tax/reimbursement
        // reports). If it fires, the old trip has already been ended and a
        // new one started for the new vehicle; this specific location fix
        // belongs to neither cleanly, so we drop it and let the next update
        // populate the new trip.
        if checkVehicleSwitch() { return }

        guard var trip = activeTrip else { return }
        lastLocationAt = Date()
        lastAccuracy = location.horizontalAccuracy
        let speedKmh = max(0, location.speed) * 3.6
        trip.lastSpeedKmh = speedKmh

        let previous = CLLocation(latitude: trip.lastLat, longitude: trip.lastLng)
        let metres = location.distance(from: previous)
        if metres > 10 {
            trip.distanceKm += metres / 1000.0
            trip.lastLat = location.coordinate.latitude
            trip.lastLng = location.coordinate.longitude
            trip.points.append(RecordedPoint(
                recordedAt: location.timestamp,
                lat: location.coordinate.latitude,
                lng: location.coordinate.longitude,
                speedKmh: Float(speedKmh),
                accuracyM: Float(location.horizontalAccuracy)
            ))
            // Distance-based movement check: with distanceFilter = 10m iOS
            // often reports speed = 0 at the moment of an update (snapshot
            // between stop-and-go updates), so the speed check alone misses
            // active driving and the audit then ends the trip as 'stationary'
            // even though km kept piling up. Anything > 10m of actual GPS
            // travel is irrefutable movement.
            trip.lastMovementAt = Date()
        }
        if speedKmh >= movingSpeedKmh {   // genuinely moving
            trip.lastMovementAt = Date()
        }
        activeTrip = trip
        persistActiveTrip()
        // NOTE: stationary-based trip ending is intentionally NOT done here
        // per-update — it's centralized in auditActiveTrip() exclusively, so
        // there's exactly one place that decides "is this trip over", using
        // one consistent elapsed-time-since-movement rule. CLLocationManager
        // doesn't call this method while genuinely stationary anyway (no
        // update exceeds distanceFilter), so centralizing costs at most
        // ~60s of extra detection latency against a multi-minute timeout.
    }

    // MARK: - Trip end

    /// `endedAt` defaults to now, correct for a force-stop or a detected
    /// vehicle switch — those are real events happening at call time. The
    /// stationary-timeout path overrides this with the trip's actual last
    /// movement instant: if the app was fully suspended while the car sat
    /// parked (confirmed by field data — a real trip once needed ~4h47m
    /// before iOS gave the app any execution window to run this audit at
    /// all, having genuinely stopped moving only 22s after its own start),
    /// stamping `endedAt = Date()` would record the trip as having run for
    /// hours it was actually just sitting parked and suspended.
    private func endTrip(reason: String, at endedAt: Date = Date()) {
        guard let state = activeTrip else { return }

        // Discard very-short trips entirely — they're auto-detector noise
        // (the wake fired but the car only moved a few metres of GPS jitter,
        // or it ended before any meaningful movement landed). Threshold at
        // 200 m: anything shorter is below normal urban-block distance and
        // almost always GPS noise rather than a real reimbursable trip.
        let minTripKm = 0.2
        if state.distanceKm < minTripKm {
            log.log(String(format: "Trip discarded (%@): %.2f km < %.1f km threshold.",
                           reason, state.distanceKm, minTripKm), level: .info)
            manager.stopUpdatingLocation()
            motion.stop()
            stopAuditTimer()
            activeTrip = nil
            clearPersistedActiveTrip()
            return
        }

        let vehicle = store.vehicle(state.vehicleID) ?? store.vehicles.first
            ?? Vehicle(name: "Unknown", licensePlate: "", type: .own)

        let endCoord = CLLocationCoordinate2D(latitude: state.lastLat, longitude: state.lastLng)
        let startCoord = CLLocationCoordinate2D(latitude: state.startLat, longitude: state.startLng)

        let classified = TripClassifier.classify(
            vehicle: vehicle,
            settings: store.settings,
            startedAt: state.startedAt,
            startCoord: startCoord,
            endCoord: endCoord
        )

        // If we've seen a customer near this end location before, auto-fill
        // the name so the user only has to confirm via the notification.
        let learnedCustomer = CustomerSuggester.suggest(near: endCoord, in: store.trips)
        let customer = (classified.customerName?.isEmpty == false ? classified.customerName : nil)
            ?? learnedCustomer
            ?? ""

        var trip = Trip(
            id: state.id,
            vehicleID: state.vehicleID,
            type: classified.type,
            purpose: "",
            customerName: customer,
            startedAt: state.startedAt,
            endedAt: endedAt,
            startAddress: "",
            endAddress: "",
            distanceKm: state.distanceKm,
            notes: "Auto-detected",
            isLocked: false
        )
        trip.startLat = state.startLat
        trip.startLng = state.startLng
        trip.endLat = state.lastLat
        trip.endLng = state.lastLng
        store.addTrip(trip)
        log.log(String(format: "Trip ended (%@): %.1f km → %@",
                       reason, state.distanceKm, classified.type.label), level: .info)

        // Notify the user so they can quick-classify.
        if let notifications {
            Task { await notifications.sendClassifyNotification(for: trip) }
        }

        // Sync the GPS polyline to Supabase so the trip detail can render the route.
        if let supabase = store.supabaseService {
            let dtos = state.points.map {
                TripPointDTO(
                    trip_id: state.id,
                    recorded_at: $0.recordedAt,
                    lat: $0.lat, lng: $0.lng,
                    speed_kmh: $0.speedKmh, accuracy_m: $0.accuracyM
                )
            }
            Task { try? await supabase.pushTripPoints(dtos) }
        }

        // Reverse-geocode start/end addresses lazily and patch the saved trip.
        // Explicit @MainActor + [storeRef] capture keeps Swift 6 strict
        // concurrency happy: storeRef is the only captured reference and
        // the actor isolation matches store.updateTrip's requirements
        // (so no await needed there — only the geocoder calls are async).
        let storeRef = store
        Task { @MainActor [trip, startCoord, endCoord, storeRef] in
            let start = await Self.reverseGeocode(startCoord)
            let end = await Self.reverseGeocode(endCoord)
            var t = trip
            t.startAddress = start
            t.endAddress = end
            storeRef.updateTrip(t)
        }

        manager.stopUpdatingLocation()
        motion.stop()
        stopAuditTimer()
        activeTrip = nil
        clearPersistedActiveTrip()
    }

    private static func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
            let parts = [placemark.thoroughfare, placemark.locality].compactMap { $0 }
            return parts.joined(separator: ", ")
        }
        return ""
    }

    // MARK: - Audio route changes (vehicle identification only — never ends a trip)

    @objc nonisolated private func audioRouteChanged(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.log("Audio route change: \(reason)")
            guard self.activeTrip != nil else { return }

            // Immediate vehicle-switch/identification check — a new car's
            // Bluetooth becoming the active route is exactly what
            // .newDeviceAvailable means, so we don't wait for the next 60s
            // audit tick to notice it. This never ends the trip on its own;
            // it only reassigns/confirms which vehicle it belongs to.
            if reason == .newDeviceAvailable, self.checkVehicleSwitch() {
                return
            }

            // A disconnect (.oldDeviceUnavailable) does NOT end the trip —
            // Bluetooth plays no role in the end decision at all. Just run
            // a normal audit pass so the movement-based stationary check
            // gets an extra, prompt opportunity to run.
            if reason == .oldDeviceUnavailable {
                self.lastAuditAt = .distantPast   // bypass dedupe for this check
                self.auditActiveTrip()
            }
        }
    }

    // MARK: - Persistence of active trip + verification candidate

    private var candidateURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("active-candidate.json")
    }

    private struct PersistedCandidate: Codable {
        var startedAt: Date
    }

    /// Writes the active trip to disk for crash/kill recovery. Throttled to
    /// avoid a full JSON re-encode + file rewrite on every single GPS
    /// callback — on a long drive those can arrive every few metres, and
    /// adversarial review flagged that I/O cost as ironically risking the
    /// exact dropped/delayed-callback problem this detector exists to avoid.
    /// `force` bypasses the throttle for state-transition moments (trip
    /// start, vehicle switch, merge) where an accurate on-disk snapshot
    /// immediately after the transition matters most.
    private func persistActiveTrip(force: Bool = false) {
        guard let trip = activeTrip else { return }
        guard force || Date().timeIntervalSince(lastPersistAt) >= persistThrottleSeconds else { return }
        lastPersistAt = Date()
        try? JSONEncoder().encode(trip).write(to: activeTripURL)
    }

    private func clearPersistedActiveTrip() {
        try? FileManager.default.removeItem(at: activeTripURL)
    }

    private func persistCandidate() {
        guard let c = candidate else { return }
        let p = PersistedCandidate(startedAt: c.startedAt)
        try? JSONEncoder().encode(p).write(to: candidateURL)
    }

    private func clearPersistedCandidate() {
        try? FileManager.default.removeItem(at: candidateURL)
    }

    /// On launch, restore an in-progress trip if there is one, and clean up
    /// stale verification candidates left from a previous run that was
    /// killed mid-verification.
    private func restoreActiveTripIfAny() {
        // 1. Stale candidate cleanup — if the previous run was killed while
        //    verifying, the candidate file may be hours old. Drop anything
        //    older than 2x the verification window.
        if let data = try? Data(contentsOf: candidateURL),
           let p = try? JSONDecoder().decode(PersistedCandidate.self, from: data) {
            let age = Date().timeIntervalSince(p.startedAt)
            if age > verificationSeconds * 2 {
                log.log("Cleared stale verification candidate (age \(Int(age))s).", level: .info)
                clearPersistedCandidate()
            }
        }

        // 2. Restore in-progress trip and resume GPS + audit so the trip's
        //    end (stationary timeout) can still be detected.
        guard let data = try? Data(contentsOf: activeTripURL),
              let trip = try? JSONDecoder().decode(ActiveTripState.self, from: data) else { return }
        activeTrip = trip
        log.log("Restored in-progress trip after relaunch; resumed GPS and audit.", level: .info)

        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        startAuditTimer()

        // Evaluate immediately rather than waiting for the next timer tick.
        // Field data showed the app can be killed and relaunched by iOS
        // several times across a single long trip; each relaunch is a
        // chance to promptly close out a trip that's actually been
        // stationary the whole time the app was dead, rather than silently
        // extending it further until the next scheduled audit. Marked
        // isPostRelaunch so a resulting closure is flagged for reclaim
        // rather than treated as a confirmed stop — see
        // relaunchRecoveryContext's doc comment.
        auditActiveTrip(isPostRelaunch: true)
    }
}

extension TripDetector: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            let previous = self.permission
            self.permission = status
            self.log.log("Location authorization changed: \(status.label)")
            if status == .authorizedAlways && self.store.settings.autoDetectEnabled && !self.isEnabled {
                self.startMonitoring()
            }
            // A downgrade from Always silently breaks background auto-detect:
            // CLLocationManager just stops waking the app, with no crash or
            // error to notice — confirmed by a real field case where the app
            // went quiet for a full week after an undetected downgrade to
            // "While Using" (2026-07-21 log), discoverable only via the
            // passive Settings/Record-tab hint that nobody had a reason to
            // go looking at. Alert immediately instead of relying on that.
            if previous == .authorizedAlways, status != .authorizedAlways,
               self.store.settings.autoDetectEnabled {
                self.log.log("Auto-detect background tracking has stopped — permission dropped from Always to \(status.label).",
                              level: .warning)
                if let notifications = self.notifications {
                    Task { await notifications.sendPermissionDowngradedNotification() }
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activeTrip != nil {
                self.updateActiveTrip(with: loc)
            } else if self.candidate != nil {
                self.updateVerification(with: loc)
            } else {
                self.handleSignificantLocation(loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.log.log("Location error: \(error.localizedDescription)", level: .error)
        }
    }

    /// iOS itself decided we're stationary and paused GPS — happens in Low
    /// Power energy mode. Defers to auditActiveTrip() rather than ending
    /// unconditionally, so the same single elapsed-time-since-movement rule
    /// decides whether the trip is actually over.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.log("iOS auto-paused location updates (stationary).", level: .info)
            if self.activeTrip != nil {
                self.lastAuditAt = .distantPast   // bypass dedupe for this check
                self.auditActiveTrip()
            }
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.log.log("iOS resumed location updates.")
        }
    }
}

private extension CLAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorizedAlways:     return "always"
        case .authorizedWhenInUse:  return "whenInUse"
        @unknown default:    return "unknown"
        }
    }
}
