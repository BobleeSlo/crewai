import Foundation
import CoreLocation
import AVFoundation
import Combine
import UIKit

/// In-progress auto trip kept on disk so it survives the app being killed.
///
/// Hand-written Codable: the compiler-synthesized Decodable does NOT apply a
/// stored property's default value when its key is simply missing from the
/// JSON — it throws `keyNotFound` regardless (a well-known Swift gotcha; only
/// Optional-typed properties get an implicit `decodeIfPresent`). `lastSpeedKmh`
/// and `points` were added in later phases, so a persisted active-trip.json
/// written by an older build (mid-trip, right when the user updates the app)
/// would otherwise fail to decode entirely on the first post-update launch —
/// silently losing that in-progress trip with no trace, the same class of bug
/// this custom init already protects `Vehicle` and `UserSettings` against
/// elsewhere in this file (adversarial review finding).
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

    init(id: UUID, vehicleID: UUID, audioDeviceUID: String? = nil, audioDeviceName: String? = nil,
        startedAt: Date, startLat: Double, startLng: Double, lastLat: Double, lastLng: Double,
        distanceKm: Double, lastMovementAt: Date, lastSpeedKmh: Double = 0,
        points: [RecordedPoint] = []) {
        self.id = id
        self.vehicleID = vehicleID
        self.audioDeviceUID = audioDeviceUID
        self.audioDeviceName = audioDeviceName
        self.startedAt = startedAt
        self.startLat = startLat
        self.startLng = startLng
        self.lastLat = lastLat
        self.lastLng = lastLng
        self.distanceKm = distanceKm
        self.lastMovementAt = lastMovementAt
        self.lastSpeedKmh = lastSpeedKmh
        self.points = points
    }

    enum CodingKeys: String, CodingKey {
        case id, vehicleID, audioDeviceUID, audioDeviceName, startedAt
        case startLat, startLng, lastLat, lastLng, distanceKm, lastMovementAt
        case lastSpeedKmh, points
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vehicleID = try c.decode(UUID.self, forKey: .vehicleID)
        audioDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioDeviceUID)
        audioDeviceName = try c.decodeIfPresent(String.self, forKey: .audioDeviceName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        startLat = try c.decode(Double.self, forKey: .startLat)
        startLng = try c.decode(Double.self, forKey: .startLng)
        lastLat = try c.decode(Double.self, forKey: .lastLat)
        lastLng = try c.decode(Double.self, forKey: .lastLng)
        distanceKm = try c.decode(Double.self, forKey: .distanceKm)
        lastMovementAt = try c.decode(Date.self, forKey: .lastMovementAt)
        lastSpeedKmh = try c.decodeIfPresent(Double.self, forKey: .lastSpeedKmh) ?? 0
        points = try c.decodeIfPresent([RecordedPoint].self, forKey: .points) ?? []
    }
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
    // Plain strong references, not unowned/weak: neither Store nor
    // DetectionLog holds a reference back to TripDetector, so there's no
    // retain cycle to break — unowned only trades that non-existent cycle
    // for a real crash-on-dangling-reference risk if the wiring in
    // MileLogApp.init() ever changes (adversarial review finding).
    private let store: Store
    private let log: DetectionLog
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
    /// Fixes delivered since the last heartbeat. A healthy trip sees many;
    /// one per heartbeat means iOS is waking the app periodically rather
    /// than streaming, and the distance is being measured as straight lines
    /// between minutes-apart points.
    private var fixesSinceLastHeartbeat = 0
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

    /// True once the user has been told a detected drive couldn't be saved
    /// for lack of any registered vehicle. Keeps that alert to once per
    /// spell rather than once per drive (round-5 UX review finding); reset
    /// by `startMonitoring()` so a later relapse alerts again.
    private var hasWarnedNoVehicle = false

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
    /// Only arm the reclaim when the observed gap clearly exceeds what a
    /// normal stop should ever produce — an ordinary errand a little over
    /// `stationaryTimeoutMinutes` that happens to coincide with an unrelated
    /// relaunch must NOT be flagged, or a later, genuinely separate trip in
    /// the same vehicle could get force-merged into it (adversarial review
    /// finding). This is a MARGIN ABOVE the user's own configured
    /// `stationaryTimeoutMinutes` (Settings-adjustable 2-20 min), not a bare
    /// absolute number — a bare constant here previously sat below the top
    /// of that range, which made the guard a complete no-op for any user
    /// with a longer timeout configured, since `auditActiveTrip` already
    /// guarantees `stationaryMin >= timeout` before this is ever checked
    /// (round-2 adversarial review finding).
    ///
    /// Tradeoff, accepted deliberately: for a user with a long configured
    /// timeout (near 20 min), the resulting threshold (up to 35 min) can
    /// exceed the smallest field-confirmed app-kill-during-driving gap
    /// (23 min), so some real relaunch fragmentation for that user won't
    /// auto-heal. That's the right side to err on — a user who tolerates
    /// longer real stops makes "real stop" and "app died" harder to tell
    /// apart, and under-merging (an occasional extra, correctly-attributed
    /// trip row) is far cheaper than over-merging (silently corrupting a
    /// genuinely separate trip's classification and distance).
    private let relaunchRecoveryMinGapAboveTimeoutMinutes: Double = 15
    /// Sanity bound on the reclaim itself: the new trip's start must be
    /// reachable from the old trip's last known point within the elapsed
    /// gap at a generous highway speed — otherwise this isn't a
    /// continuation, it's a coincidence (adversarial review finding).
    private let relaunchRecoveryMaxSpeedKmh: Double = 160

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
        store.saveSettings()
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
        clearPersistedRelaunchRecoveryContext()
    }

    /// Re-arms monitoring if the user's saved preference says it should be
    /// on. `startMonitoring()` is otherwise reachable only from `init`, the
    /// Auto-detect toggle, and an OS authorization change — so anything
    /// that calls `disable()` mid-session (sign-out, an account switch)
    /// left auto-detect dead until the next app relaunch, while
    /// `settings.autoDetectEnabled` stayed `true` and BOTH toggles kept
    /// rendering ON and the status kept reading "Starting…" forever. Every
    /// drive after that went silently unrecorded (round-6 UX review
    /// finding — a regression from round 5's own sign-out fix). Safe to
    /// call repeatedly: `startMonitoring()` early-returns when already on.
    func syncToSettings() {
        // BOTH directions. The original `resumeIfEnabled()` only ever
        // turned monitoring ON, so adopting a cloud settings copy that has
        // `autoDetectEnabled == false` — over a detector the user had just
        // switched on during the sync — left real GPS monitoring running
        // while the Record screen read "Off — trips won't be detected
        // automatically". Nothing in the detection path re-reads that flag,
        // so the desync was permanent for the session: unexpected
        // background GPS and surprise auto-recorded trips, with the UI
        // insisting it was off (round-9 UX review finding).
        if store.settings.autoDetectEnabled {
            guard permission == .authorizedAlways, !isEnabled else { return }
            startMonitoring()
            log.log("Auto-detect re-armed after a session change.", level: .info)
        } else if isEnabled {
            stopMonitoring()
            log.log("Auto-detect stopped to match this account's saved setting.", level: .info)
        }
    }

    /// Discards an in-progress trip WITHOUT saving or pushing it anywhere —
    /// unlike every other trip-ending path, which always calls `endTrip()`
    /// and therefore always (past the noise threshold) adds it to
    /// `store.trips` and pushes it to Supabase. Exists specifically for
    /// `Store.initialSync`'s account-switch handling: a trip active at the
    /// exact moment the signed-in identity changes cannot be safely
    /// attributed to either the old or the new account, and routing it
    /// through `disable()` (which calls `endTrip()`) was found to let such
    /// a trip's data — and a `pushTrip` call tagged with whatever identity
    /// is CURRENTLY authenticated — escape into the new account before the
    /// caller ever got to wipe local state (round-6 adversarial review
    /// finding: a confirmed cross-account leak surviving specifically for
    /// this one moment, distinct from the round-5 fix for the steady-state
    /// case). Call this BEFORE `disable()` and before touching
    /// `store.trips`/`vehicles`/`settings` or `store.supabaseService` —
    /// `disable()` afterward safely no-ops its own `endTrip()` call since
    /// `activeTrip` is already nil, so it still handles the rest of the
    /// teardown (stopping monitoring, clearing any pending candidate) as
    /// normal.
    func discardActiveTripForAccountSwitch() {
        guard activeTrip != nil else { return }
        log.log("Discarding in-progress trip — signed-in account changed mid-drive; it can't be safely attributed to either account.",
                level: .warning)
        manager.stopUpdatingLocation()
        motion.stop()
        stopAuditTimer()
        activeTrip = nil
        clearPersistedActiveTrip()
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
        // Clear the once-per-spell no-vehicle warning: if the user has
        // since added a vehicle this is moot, and if they haven't, they
        // deserve to be told again the next time a drive is lost.
        hasWarnedNoVehicle = false
        log.log("Auto-detect ON.", level: .info)
    }

    private func stopMonitoring() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        motion.stop()
        verificationDeadline?.invalidate()
        verificationDeadline = nil
        candidate = nil
        clearPersistedCandidate()
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
        // Auto-pause off for the duration of the trip, whatever the energy
        // mode says: a paused manager suspends the app, which stops the
        // audit timer and leaves the trip open until the next launch.
        store.settings.energyMode.apply(to: manager, duringActiveTrip: true)
        // The blue status-bar pill. Also the only way to see, at a glance
        // while driving, whether iOS is actually running background
        // location for us — if it is missing, it is not.
        manager.showsBackgroundLocationIndicator = true
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

        // Reject invalid/low-quality fixes before trusting them as movement
        // evidence — a negative accuracy means CoreLocation itself
        // considers the fix invalid, and a coarse one (multipath in a
        // garage/urban canyon — exactly the GPS-dead-zone conditions this
        // file already accounts for elsewhere) can "wander" tens to
        // hundreds of metres between callbacks, producing a false-positive
        // automotive-movement confirmation from jitter alone rather than a
        // real drive (adversarial review finding). Scaled to the active
        // energy mode rather than one shared constant — a fixed 50m ceiling
        // was self-inconsistent with lowPower's own ~100m accuracy target
        // (round-4 adversarial review finding).
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < store.settings.energyMode.maxAcceptableGPSAccuracy else { return }

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
            let confirmedVehicle = matchVehicle(for: device)
            let vehicle = confirmedVehicle ?? fallbackVehicle()
            guard let vehicle else {
                log.log("Verification passed but no vehicle is registered at all — trip dropped.", level: .error)
                // Tear down exactly like the FAILED branch below. Round 4
                // added the notification here but returned without stopping
                // anything — and since `candidate` was just cleared above,
                // the very next GPS fix restarted verification, passed
                // early on the first >25 km/h fix, and dropped again. That
                // looped for the whole drive: a re-alerting banner every
                // few seconds plus continuous GPS and CoreMotion with
                // background updates held, in exactly the first-run state
                // the notification was written for (round-5 UX review
                // finding — a regression from round 4's own fix).
                motion.stop()
                manager.stopUpdatingLocation()
                // Only alert once per "user still has no vehicle" spell,
                // rather than once per detected drive. Reset in
                // `setAutoDetect`/`startMonitoring` once a vehicle exists.
                if let notifications, !hasWarnedNoVehicle {
                    hasWarnedNoVehicle = true
                    Task { await notifications.sendNoVehicleTripDroppedNotification() }
                }
                return
            }
            // A vehicle exists again, so a FUTURE no-vehicle spell should
            // warn afresh. Resetting only in `startMonitoring()` wasn't
            // enough: that early-returns when monitoring is already on, so
            // a user who deleted their last vehicle while auto-detect was
            // running would be warned once and then never again (round-6
            // UX review finding).
            hasWarnedNoVehicle = false
            // Log whenever the vehicle is an unconfirmed GUESS, not just a
            // name-only BT match (matchVehicle already warns for that case)
            // — otherwise a silently wrong vehicle attribution has zero
            // trace in the Detection log to explain it (round-2 adversarial
            // review finding).
            if confirmedVehicle == nil {
                log.log("No Bluetooth match — guessing vehicle from most recent trip: \(vehicle.name). Verify this trip's vehicle is correct.",
                        level: .warning)
            }
            // allowMerge is disabled whenever the vehicle is only a GUESS
            // (fallbackVehicle picks "whichever vehicle was most recently
            // driven", which is exactly wrong when it's wrong: a car with no
            // reliable BT pairing driven right after a different, confirmed
            // vehicle would otherwise get its own trip silently merged INTO
            // that other vehicle's just-ended trip — extending its distance
            // and back-dating its start across what was actually a totally
            // separate drive in a totally different vehicle. Confirmed vs.
            // fallback identification must never carry equal weight for a
            // decision this consequential (adversarial review finding).
            // The trip still starts (with the best guess available), it
            // just can't silently absorb someone else's confirmed trip.
            //
            // …unless the user started a manual recording while this
            // verification window was open. `handleSignificantLocation`
            // guards against that case before ARMING verification, but
            // nothing re-checked it before COMMITTING ~90s later, and
            // `LocationManager.start()` only refuses when a trip is
            // already active — a pending candidate doesn't stop it. So
            // both recorders could end up live on the same drive, and
            // because RecordTripView renders its Stop button as
            // `if !autoActive`, the manual recording's only stop control
            // vanished the moment the auto trip committed — leaving it
            // running with background location held until the same drive
            // got saved twice, double-counting km in a tax report
            // (round-5 UX review finding). The user's explicit tap wins.
            if let manual = manualLocationManager, manual.isTracking {
                log.log("Verification passed, but a manual recording is already in progress — leaving this drive to the manual recorder.",
                        level: .warning)
                motion.stop()
                manager.stopUpdatingLocation()
                return
            }
            commitTripStart(at: c.startLocation, startedAt: c.startedAt,
                            vehicle: vehicle, device: device,
                            allowMerge: confirmedVehicle != nil)
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
        // Auto-pause off for the duration of the trip, whatever the energy
        // mode says: a paused manager suspends the app, which stops the
        // audit timer and leaves the trip open until the next launch.
        store.settings.energyMode.apply(to: manager, duringActiveTrip: true)
        // The blue status-bar pill. Also the only way to see, at a glance
        // while driving, whether iOS is actually running background
        // location for us — if it is missing, it is not.
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        startAuditTimer()

        let bt = device.map { "BT \($0.name)" } ?? "no BT"
        log.log("Trip started: \(vehicle.name) [\(bt)] · \(store.settings.energyMode.label)", level: .info)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            log.log("Low Power Mode is ON. iOS throttles background location hard in this mode — expect sparse fixes, under-measured distance, and trips that only close when the app is next opened.",
                    level: .warning)
        }
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
                // "unobserved," not "genuinely stopped." Only worth flagging
                // for reclaim when the gap is anomalously large, though: an
                // ordinary stop just a little over the timeout (a red light,
                // a quick errand) that happens to coincide with a relaunch
                // is still a perfectly normal, trustworthy ending — arming
                // the reclaim for THAT would risk force-merging a later,
                // genuinely separate trip (adversarial review finding).
                // relaunchRecoveryMinGapAboveTimeoutMinutes filters for gaps
                // clearly beyond what a real stop should ever produce,
                // scaled off this user's own configured timeout rather than
                // a bare constant (round-2 adversarial review finding).
                if isPostRelaunch, stationaryMin >= timeout + relaunchRecoveryMinGapAboveTimeoutMinutes {
                    // This is a single slot, not a queue — if an earlier
                    // reclaim opportunity is still within its own window and
                    // hasn't been consumed yet, overwriting it here silently
                    // forfeits it. Rare (requires two distinct trips each
                    // getting relaunch-interrupted within overlapping
                    // windows) but worth a log line rather than silence
                    // (adversarial review finding).
                    if let stale = relaunchRecoveryContext,
                       Date().timeIntervalSince(stale.endedAt) < relaunchRecoveryWindowMinutes * 60 {
                        log.log("Overwriting a still-valid, unconsumed relaunch-recovery context (vehicle \(store.vehicleName(stale.vehicleID))) — its reclaim window is now forfeited.",
                                level: .warning)
                    }
                    relaunchRecoveryContext = (tripID: trip.id, vehicleID: trip.vehicleID, endedAt: trip.lastMovementAt)
                    persistRelaunchRecoveryContext()
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
            gpsHealth = String(format: "GPS %ds ago · acc %.0f m · %d fixes since last beat",
                               secsSinceGPS, max(0, lastAccuracy), fixesSinceLastHeartbeat)
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
        // Why the background state is on every heartbeat: field logs showed
        // a 60-second audit timer firing every 300 seconds with each fix
        // ~290s stale — the signature of an app iOS is not letting run,
        // even though the code arms background updates correctly. Nothing
        // in the old heartbeat could distinguish "iOS suspended us",
        // "Low Power Mode throttled us" and "auto-pause fired", so this
        // records all three. A healthy background heartbeat reads
        // `app bg · bgUpdates on · autoPause off · lowPower off` with GPS a
        // few seconds old; anything else names the culprit directly.
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active:     appState = "fg"
        case .inactive:   appState = "inactive"
        case .background: appState = "bg"
        @unknown default: appState = "?"
        }
        let background = String(
            format: "app %@ · bgUpdates %@ · autoPause %@ · lowPower %@",
            appState,
            manager.allowsBackgroundLocationUpdates ? "on" : "OFF",
            manager.pausesLocationUpdatesAutomatically ? "ON" : "off",
            ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off")

        log.log(String(format: "AUDIT heartbeat: %.1f km · v %.0f km/h · %.0f min since movement (ends at %.0f) · BT %@ · motion %@ · %@ · %@",
                       trip.distanceKm,
                       trip.lastSpeedKmh,
                       stationaryMin,
                       timeout,
                       btLabel,
                       motionLabel,
                       gpsHealth,
                       background))
        fixesSinceLastHeartbeat = 0
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
           // Same !isLocked guard as the normal merge path below — currently
           // unreachable in practice (relaunchRecoveryWindowMinutes is far
           // smaller than any realistic lockAfterDays), but kept consistent
           // rather than latent (round-2 adversarial review finding).
           // reviewedAt == nil matters a lot more here than !isLocked does:
           // the relaunch-recovery window is up to 90 minutes, plenty of
           // time for the user to tap the classify notification this trip
           // got when it closed — reclaiming it after that would discard
           // their review (adversarial review finding).
           let lastTrip = store.trips.first(where: { $0.id == ctx.tripID && !$0.isLocked && $0.reviewedAt == nil }),
           // Same intervening-vehicle guard as the normal merge path below —
           // if a different vehicle was genuinely driven in between, this
           // isn't a continuation, it's a real return to vehicle A later.
           !store.trips.contains(where: { $0.vehicleID != vehicle.id && $0.startedAt > ctx.endedAt }) {
            let elapsedGapSeconds = Date().timeIntervalSince(ctx.endedAt)
            // Plausibility bound: the new start must be reachable from the
            // old trip's last known point within the gap at a generous
            // highway speed. Without this, a same-vehicle trip that starts
            // somewhere completely unrelated hours later (a genuinely
            // separate errand, not a continuation) would still get
            // force-merged (adversarial review finding). No last-known
            // point at all (shouldn't happen — endTrip always sets one) is
            // treated as unable to refute plausibility rather than blocking.
            let distance: CLLocationDistance = {
                guard let endLat = lastTrip.endLat, let endLng = lastTrip.endLng else { return 0 }
                return CLLocation(latitude: endLat, longitude: endLng).distance(from: location)
            }()
            let maxPlausibleMetres = (elapsedGapSeconds / 3600) * relaunchRecoveryMaxSpeedKmh * 1000

            relaunchRecoveryContext = nil
            clearPersistedRelaunchRecoveryContext()

            if distance <= maxPlausibleMetres {
                log.log(String(format: "Reclaiming trip interrupted by app relaunch (gap %.0f min, %.0f m from last known point) — continuing rather than starting fresh.",
                               elapsedGapSeconds / 60, distance), level: .info)
                resumeTrip(lastTrip, at: location, vehicle: vehicle, device: device)
                return true
            }
            log.log(String(format: "Relaunch-recovery skipped: %.0f m from last known point exceeds plausible travel for a %.0f min gap — treating as a separate trip.",
                           distance, elapsedGapSeconds / 60), level: .warning)
        }

        guard let lastTrip = store.trips
            // reviewedAt != nil excluded: a human has already classified/
            // edited this trip, so it's done — resurrecting it as
            // in-progress again would silently discard that review at the
            // next real end, since ActiveTripState can't carry it forward
            // (adversarial review finding, Trip.reviewedAt's doc comment).
            .filter({ $0.vehicleID == vehicle.id && !$0.isLocked && $0.reviewedAt == nil })
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
        // Deliberately NOT deleting the Supabase row here (dropped after
        // adversarial review). endTrip's own reverse-geocode Task finishes
        // asynchronously and later calls store.updateTrip for this same
        // trip id — an unawaited delete racing against that unawaited
        // update, with no ordering guarantee between the two independent
        // network calls, could let the update's upsert resurrect the row
        // AFTER the delete completed. Simply leaving the old row in place
        // is safe: distanceKm only ever grows, so whenever this resumed
        // trip truly ends, endTrip's normal pushTrip (upsert, same id)
        // naturally overwrites it with the final, correct data — no delete
        // needed to get there, and no race to have in the first place.

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
        // Auto-pause off for the duration of the trip, whatever the energy
        // mode says: a paused manager suspends the app, which stops the
        // audit timer and leaves the trip open until the next launch.
        store.settings.energyMode.apply(to: manager, duringActiveTrip: true)
        // The blue status-bar pill. Also the only way to see, at a glance
        // while driving, whether iOS is actually running background
        // location for us — if it is missing, it is not.
        manager.showsBackgroundLocationIndicator = true
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

        // UID match is trusted unconditionally ONLY when it's unique. It
        // normally is (a UID identifies one physical device) — but nothing
        // stops a user from re-capturing "this car's Bluetooth" for vehicle
        // B while still connected to vehicle A (VehiclesView's capture flow
        // just copies whatever device.uid is currently connected), leaving
        // two vehicles sharing a UID. Apply the same ambiguity refusal
        // already used for the name-match fallback below, rather than
        // silently picking .first (round-9 adversarial review finding).
        let uidMatches = pool.filter { !$0.bluetoothUID.isEmpty && $0.bluetoothUID == device.uid }
        if uidMatches.count == 1 {
            return uidMatches[0]
        }
        if uidMatches.count > 1 {
            log.log("AMBIGUOUS BT UID for '\(device.name)' matches \(uidMatches.count) active vehicles (\(uidMatches.map(\.name).joined(separator: ", "))) — refusing to guess. Re-pair each vehicle from its own Bluetooth connection so their IDs are unique.",
                    level: .error)
            return nil
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
        fixesSinceLastHeartbeat += 1
        lastAccuracy = location.horizontalAccuracy
        let speedKmh = max(0, location.speed) * 3.6
        trip.lastSpeedKmh = speedKmh

        // Reject invalid/low-quality fixes before trusting them as movement
        // evidence. Previously ANY position delta over 10m was treated as
        // "irrefutable movement" with no accuracy check at all — a fix with
        // negative accuracy (CoreLocation's own "invalid" marker) or a
        // coarse one (multipath in a garage/urban canyon — exactly the GPS-
        // dead-zone conditions this file already accounts for elsewhere)
        // can wander well past that threshold between callbacks, both
        // inflating distanceKm and indefinitely refreshing lastMovementAt —
        // recreating this app's founding failure mode (a trip that never
        // ends) via GPS noise instead of the already-fixed Bluetooth vector
        // (adversarial review finding). Scaled to the active energy mode
        // rather than one shared constant — a fixed 50m ceiling was self-
        // inconsistent with lowPower's own ~100m accuracy target (round-4
        // adversarial review finding). Diagnostics above
        // (lastLocationAt/lastAccuracy/lastSpeedKmh) and the persist below
        // still reflect this fix regardless — only distance/lastMovementAt
        // accumulation is gated.
        if location.horizontalAccuracy >= 0,
           location.horizontalAccuracy < store.settings.energyMode.maxAcceptableGPSAccuracy {
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
            // A discarded trip never lands in store.trips, so any relaunch-
            // recovery flag pointing at it could never be found again —
            // clear it now rather than leave dead state to age out on its own.
            if relaunchRecoveryContext?.tripID == state.id {
                relaunchRecoveryContext = nil
                clearPersistedRelaunchRecoveryContext()
            }
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

        // Sync the GPS polyline to Supabase so the trip detail can render
        // the route. `trip_points.trip_id` has a real foreign key to
        // trips(id), checked immediately on insert — `store.addTrip`
        // above already queued its own push of the trip row, but as an
        // independent, unawaited Task with no ordering guarantee relative
        // to this one. If the points insert's request happened to complete
        // first, the FK check fails and the whole polyline is silently and
        // permanently lost (`try?`, no retry mechanism exists for points,
        // unlike trips/vehicles). Re-pushing the trip here (harmless —
        // `pushTrip` upserts) INSIDE this same Task, awaited before the
        // points push, guarantees the trip row exists first regardless of
        // how `addTrip`'s own push Task happens to interleave (round-8
        // adversarial review finding).
        if let supabase = store.supabaseService {
            let dtos = state.points.map {
                TripPointDTO(
                    trip_id: state.id,
                    recorded_at: $0.recordedAt,
                    lat: $0.lat, lng: $0.lng,
                    speed_kmh: $0.speedKmh, accuracy_m: $0.accuracyM
                )
            }
            let tripToSync = trip
            Task {
                try? await supabase.pushTrip(tripToSync)
                try? await supabase.pushTripPoints(dtos)
            }
        }

        // Reverse-geocode start/end addresses lazily and patch the saved trip.
        // Explicit @MainActor + [storeRef] capture keeps Swift 6 strict
        // concurrency happy: storeRef is the only captured reference and
        // the actor isolation matches store.updateTrip's requirements
        // (so no await needed there — only the geocoder calls are async).
        let storeRef = store
        let tripID = state.id
        let expectedEndedAt = endedAt
        Task { @MainActor [startCoord, endCoord, storeRef, tripID, expectedEndedAt] in
            let start = await Self.reverseGeocode(startCoord)
            let end = await Self.reverseGeocode(endCoord)
            // Look up whatever is CURRENTLY stored for this id rather than
            // replaying the snapshot captured back when this trip ended —
            // geocoding can take long enough (CLGeocoder has no timeout,
            // and can stall for exactly the tunnel/dead-zone conditions
            // that also trigger app relaunches) for the user to have
            // reclassified this trip via its notification, or for it to
            // have been merged/reclaimed and re-ended with different final
            // data under the same id in the meantime. Blindly replaying the
            // old snapshot would silently clobber that newer, correct state
            // with stale type/customer/distance (adversarial review
            // finding). No-ops harmlessly if the trip is gone entirely.
            guard var current = storeRef.trips.first(where: { $0.id == tripID }) else { return }
            // A trip id can be reused across a merge/reclaim + later re-end
            // (resumeTrip deliberately keeps the same id). If THIS trip
            // re-ended again before this Task resolved, endedAt will have
            // moved on — that means a SECOND, later geocode Task is also in
            // flight for the correct final leg, and patching here would
            // race it with this stale first-leg's addresses, computed from
            // coordinates that no longer describe the trip's real start/end
            // (adversarial review finding). endedAt as a cheap version
            // marker: it changes every time endTrip runs, no new field
            // needed.
            guard current.endedAt == expectedEndedAt else { return }
            current.startAddress = start
            current.endAddress = end
            storeRef.updateTrip(current)
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

    private var activeTripPointsURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("active-trip-points.json")
    }
    private var lastPointsPersistAt: Date = .distantPast
    /// `points` grows unboundedly over a long drive (a point every >10m of
    /// travel — hundreds or thousands over a multi-hour highway trip) and
    /// re-encoding the WHOLE array on every throttled write scales its cost
    /// with trip length, on the same actor that has to process time-critical
    /// GPS callbacks (round-2 adversarial review finding — undercuts the
    /// very reason the throttle below exists). Persisted separately from the
    /// lightweight header at this much coarser interval; a kill between two
    /// points-writes loses at most this many seconds of polyline (still
    /// recoverable up to that point), never the whole trip.
    private let pointsPersistIntervalSeconds: TimeInterval = 30

    /// Writes the active trip to disk for crash/kill recovery. Throttled to
    /// avoid a full JSON re-encode + file rewrite on every single GPS
    /// callback — on a long drive those can arrive every few metres, and
    /// adversarial review flagged that I/O cost as ironically risking the
    /// exact dropped/delayed-callback problem this detector exists to avoid.
    /// `force` bypasses the throttle for state-transition moments (trip
    /// start, vehicle switch, merge) where an accurate on-disk snapshot
    /// immediately after the transition matters most.
    ///
    /// The trip header (everything except `points`) and the points array
    /// are written to separate files at different cadences — see
    /// `pointsPersistIntervalSeconds`'s doc comment for why.
    private func persistActiveTrip(force: Bool = false) {
        guard let trip = activeTrip else { return }
        guard force || Date().timeIntervalSince(lastPersistAt) >= persistThrottleSeconds else { return }
        lastPersistAt = Date()

        var header = trip
        header.points = []
        try? JSONEncoder().encode(header).write(to: activeTripURL, options: .atomic)

        if force || Date().timeIntervalSince(lastPointsPersistAt) >= pointsPersistIntervalSeconds {
            lastPointsPersistAt = Date()
            try? JSONEncoder().encode(trip.points).write(to: activeTripPointsURL, options: .atomic)
        }
    }

    private func clearPersistedActiveTrip() {
        try? FileManager.default.removeItem(at: activeTripURL)
        try? FileManager.default.removeItem(at: activeTripPointsURL)
    }

    /// NOT a real crash-recovery mechanism — only `startedAt` is persisted,
    /// and `restoreActiveTripIfAny()` never rehydrates `self.candidate` from
    /// it. Its only purpose is letting the next launch recognize and discard
    /// a candidate that's gone stale because the app was killed mid-
    /// verification (see restoreActiveTripIfAny's stale-cleanup step). A
    /// kill during the ~90s verification window simply loses that partial
    /// verification; the drive gets picked up fresh on the next significant-
    /// location wake instead (adversarial review finding — flagged as
    /// acceptable given the narrow window, but worth being honest about in
    /// this comment rather than implying full resurrection).
    private func persistCandidate() {
        guard let c = candidate else { return }
        let p = PersistedCandidate(startedAt: c.startedAt)
        try? JSONEncoder().encode(p).write(to: candidateURL, options: .atomic)
    }

    private func clearPersistedCandidate() {
        try? FileManager.default.removeItem(at: candidateURL)
    }

    private var relaunchRecoveryURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("relaunch-recovery.json")
    }

    private struct PersistedRelaunchRecovery: Codable {
        var tripID: UUID
        var vehicleID: UUID
        var endedAt: Date
    }

    /// Without this, a SECOND kill before the interrupted trip gets
    /// reclaimed (e.g. during the ~90s verification window right after the
    /// relaunch that armed this) would lose the context entirely on the
    /// next relaunch, defeating the whole point for exactly the repeatedly-
    /// killed pattern this fix targets (adversarial review finding).
    private func persistRelaunchRecoveryContext() {
        guard let ctx = relaunchRecoveryContext else { return }
        let p = PersistedRelaunchRecovery(tripID: ctx.tripID, vehicleID: ctx.vehicleID, endedAt: ctx.endedAt)
        try? JSONEncoder().encode(p).write(to: relaunchRecoveryURL, options: .atomic)
    }

    private func clearPersistedRelaunchRecoveryContext() {
        try? FileManager.default.removeItem(at: relaunchRecoveryURL)
    }

    /// On launch, restore an in-progress trip if there is one, and clean up
    /// stale verification candidates left from a previous run that was
    /// killed mid-verification.
    private func restoreActiveTripIfAny() {
        // 1. Stale candidate cleanup — if the previous run was killed while
        //    verifying, the candidate file may be hours old. Drop anything
        //    older than 2x the verification window. A file that's present
        //    but fails to decode is cleared too rather than left to sit
        //    (round-3 adversarial review finding — consistency with the
        //    active-trip/relaunch-recovery handling below; low-stakes here
        //    since it's a 90s recovery window either way).
        if let data = try? Data(contentsOf: candidateURL) {
            if let p = try? JSONDecoder().decode(PersistedCandidate.self, from: data) {
                let age = Date().timeIntervalSince(p.startedAt)
                if age > verificationSeconds * 2 {
                    log.log("Cleared stale verification candidate (age \(Int(age))s).", level: .info)
                    clearPersistedCandidate()
                }
            } else {
                log.log("Found active-candidate.json but failed to decode it — discarding.", level: .warning)
                clearPersistedCandidate()
            }
        }

        // 2. Restore a pending relaunch-recovery context, if any and still
        //    within its window — otherwise a SECOND kill before the
        //    interrupted trip gets reclaimed (e.g. during the verification
        //    window right after the relaunch that armed it) would lose it
        //    entirely, defeating the point for exactly the repeatedly-killed
        //    pattern this exists for (adversarial review finding).
        if let data = try? Data(contentsOf: relaunchRecoveryURL) {
            if let p = try? JSONDecoder().decode(PersistedRelaunchRecovery.self, from: data) {
                if Date().timeIntervalSince(p.endedAt) < relaunchRecoveryWindowMinutes * 60 {
                    relaunchRecoveryContext = (tripID: p.tripID, vehicleID: p.vehicleID, endedAt: p.endedAt)
                    log.log("Restored pending relaunch-recovery context from a previous run.", level: .info)
                } else {
                    clearPersistedRelaunchRecoveryContext()
                }
            } else {
                log.log("Found relaunch-recovery.json but failed to decode it — discarding.", level: .warning)
                clearPersistedRelaunchRecoveryContext()
            }
        }

        // 3. Restore in-progress trip and resume GPS + audit so the trip's
        //    end (stationary timeout) can still be detected.
        guard let data = try? Data(contentsOf: activeTripURL) else { return }
        guard var trip = try? JSONDecoder().decode(ActiveTripState.self, from: data) else {
            log.log("Found active-trip.json but failed to decode it — an in-progress trip may have been lost.", level: .error)
            // Otherwise this same failure re-logs on every future relaunch
            // until a brand new trip happens to overwrite the file
            // (round-2 adversarial review finding).
            clearPersistedActiveTrip()
            return
        }
        // The points array is persisted separately and less often (see
        // pointsPersistIntervalSeconds) — reassemble it here. Missing/stale
        // is fine (just means up to that many seconds of polyline is gone,
        // not the whole trip).
        if let pointsData = try? Data(contentsOf: activeTripPointsURL),
           let points = try? JSONDecoder().decode([RecordedPoint].self, from: pointsData) {
            trip.points = points
        }
        activeTrip = trip
        log.log("Restored in-progress trip after relaunch; resumed GPS and audit.", level: .info)

        // CoreMotion must also restart here, not just GPS — it's a freshly
        // constructed MotionVerifier this launch (isMonitoring/lastAutomotive-
        // ActivityAt reset to their initial nil/false state), and it's
        // otherwise only ever started from commitTripStart(), which a
        // restored trip never passes through. Without this, the GPS-blackout
        // override in auditActiveTrip() can never fire for the rest of this
        // process's life — silently disabling rule 3's protection for
        // exactly the trips (already interrupted once) most likely to need
        // it again (adversarial review finding).
        if motion.isAvailable { motion.start() }

        manager.allowsBackgroundLocationUpdates = true
        // Auto-pause off for the duration of the trip, whatever the energy
        // mode says: a paused manager suspends the app, which stops the
        // audit timer and leaves the trip open until the next launch.
        store.settings.energyMode.apply(to: manager, duringActiveTrip: true)
        // The blue status-bar pill. Also the only way to see, at a glance
        // while driving, whether iOS is actually running background
        // location for us — if it is missing, it is not.
        manager.showsBackgroundLocationIndicator = true
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
