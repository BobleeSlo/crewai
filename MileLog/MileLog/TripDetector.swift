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
    /// Most recent GPS speed in km/h — logged for diagnostics and used as a
    /// "still moving" keep-alive signal.
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

/// Auto-detect engine: wakes on significant location changes, identifies the
/// car via Bluetooth audio, tracks the drive with active GPS, ends the trip on
/// BT disconnect or 5+ minutes of standing still, then saves + notifies.
///
/// Lifecycle is driven by:
///   1. CLLocationManager significant-location changes  (app wake)
///   2. Active GPS updates while a trip is running       (distance + stationary)
///   3. AVAudioSession route-change notifications        (BT disconnect)
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
    private var stationaryTimer: Timer?
    /// Recurring sanity check during a trip — fires every 60s and ends the
    /// trip if either of the normal triggers (stationary, BT disconnect)
    /// failed to deliver. Logs each tick so the Detection log shows why.
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

    // 3-strike BT-disconnect debounce: AVAudioSession occasionally flips
    // the route during the same drive (interrupting call, brief auto-
    // disconnect). Wait for N consecutive audits with the paired device
    // missing before ending the trip.
    private var consecutiveBTMisses = 0
    private let btMissesToConfirm = 3

    // Duplicate-audit suppression — the audit can occasionally fire twice
    // in rapid succession when an audio route change handler triggers a
    // re-check alongside the timer. Anything within this window is dropped.
    private var lastAuditAt: Date = .distantPast
    private let auditDedupeWindow: TimeInterval = 5

    // GPS health diagnostics so a future "GPS interrupted" complaint
    // becomes obvious in the Detection log.
    private var lastLocationAt: Date = .distantPast
    private var lastAccuracy: Double = -1

    // Trip-end policy (state-based, not pure time-based). A trip is kept
    // alive while EITHER the paired car is still connected OR the car is
    // still moving — so traffic-light stops, quiet CarPlay stretches, and
    // GPS-stale suspension gaps don't prematurely end a real drive. The
    // trip ends only when the car is BOTH disconnected AND stationary.
    //   - movingSpeedKmh: at/above this the car counts as "moving".
    //   - The stationary timeout (UserSettings.stationaryTimeoutMinutes)
    //     only ends a trip that has NO BT pairing (manual-ish case).
    //   - stationaryHardCapMinutes: absolute backstop — even with BT
    //     reported present, end after this long with zero movement, so a
    //     stuck/false "connected" reading can't run a trip forever.
    private let movingSpeedKmh: Double = 3
    private let stationaryHardCapMinutes: Double = 30

    // Vehicle-switch debounce: require the newly-detected vehicle's BT to be
    // observed consistently for this long before actually switching, so a
    // one-off BLE proximity flicker (e.g. briefly picking up a nearby parked
    // car's signal) can't fragment a real drive into extra rows. BT-loss
    // uses a 3-strike counter spaced ~60s apart (audit cadence); BT-gain is
    // checked far more often (every GPS update + every route-change event),
    // so a short wall-clock window is used instead of a tick counter.
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
    }

    /// User-initiated stop from the Record-tab banner. Records exactly why
    /// the auto trigger didn't fire (stationary time + BT presence) so the
    /// Detection log captures the post-mortem.
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
                btStatus = "BT disconnected (auto-stop should have fired)"
            }
        } else {
            btStatus = "no BT pairing at start"
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
            motion.stop()
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
        consecutiveBTMisses = 0
        pendingSwitchVehicleID = nil
        pendingSwitchFirstSeenAt = nil

        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        startAuditTimer()

        let bt = device.map { "BT \($0.name)" } ?? "no BT"
        log.log("Trip started: \(vehicle.name) [\(bt)] · \(store.settings.energyMode.label)", level: .info)
    }

    // MARK: - Audit (backup stationary + BT-disappeared detection)

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

    /// Runs every `auditIntervalSeconds` (and on each wake). State-based
    /// trip-end policy: keep the trip alive while the car is in use — i.e.
    /// while the paired Bluetooth is connected OR the car is still moving —
    /// and end ONLY when the car is both disconnected AND stationary. This
    /// stops real drives from being cut short by traffic lights, quiet
    /// CarPlay stretches, or GPS-stale suspension gaps (the failure mode
    /// seen in the field logs).
    private func auditActiveTrip() {
        guard let trip = activeTrip else {
            stopAuditTimer()
            return
        }

        // Duplicate-call suppression — a route-change handler can nudge the
        // audit just after the 60s timer fires.
        if Date().timeIntervalSince(lastAuditAt) < auditDedupeWindow { return }
        lastAuditAt = Date()

        // Vehicle-switch check runs FIRST, before any of this trip's own
        // BT/stationary bookkeeping — if the car changed, none of that
        // bookkeeping is relevant anymore.
        if checkVehicleSwitch() { return }

        let stationaryMin = Date().timeIntervalSince(trip.lastMovementAt) / 60
        let timeout = Double(store.settings.stationaryTimeoutMinutes)
        let hasPairing = trip.audioDeviceUID != nil || (trip.audioDeviceName?.isEmpty == false)

        // --- Bluetooth presence (3-strike debounce on "gone") -------------
        // Uses isPairedDevicePresent (checks outputs + available inputs) so a
        // CarPlay/BT car that's connected but not the active output during a
        // quiet stretch still counts as present.
        var btPresent = false
        if hasPairing {
            btPresent = AudioRoute.isPairedDevicePresent(uid: trip.audioDeviceUID,
                                                         name: trip.audioDeviceName)
            if btPresent {
                if consecutiveBTMisses > 0 {
                    log.log("AUDIT: paired BT device back — resetting miss counter.")
                }
                consecutiveBTMisses = 0
            } else {
                consecutiveBTMisses += 1
                // Only log while still counting toward confirmation — once
                // confirmed gone the trip may legitimately stay open via the
                // "moving" keep-alive for a long time (e.g. BT dropped mid-
                // drive due to a phone call), and re-logging this warning
                // every 60s for the rest of the drive would be pure noise.
                // The heartbeat line below still reports "missing(n)" once.
                if consecutiveBTMisses <= btMissesToConfirm {
                    log.log("AUDIT: paired BT device missing (\(consecutiveBTMisses)/\(btMissesToConfirm)).",
                            level: .warning)
                }
            }
        }
        // "Confirmed disconnected" = paired but missing for N consecutive audits.
        let btConfirmedGone = hasPairing && consecutiveBTMisses >= btMissesToConfirm
        // No pairing at all → treat as "not connected" for the end decision.
        let connected = hasPairing && !btConfirmedGone

        // --- Movement ------------------------------------------------------
        let recentlyMoving = stationaryMin < timeout

        // --- End decision --------------------------------------------------
        // 1. Normal end: car disconnected AND stationary past the timeout.
        if !connected && !recentlyMoving {
            let why = hasPairing
                ? "BT disconnected + stationary \(Int(stationaryMin)) min"
                : "no BT pairing + stationary \(Int(stationaryMin)) min"
            log.log("AUDIT: ending trip — \(why).", level: .info)
            endTrip(reason: why)
            return
        }
        // 2. Hard safety cap: even if BT still reads "present", end after a
        //    very long fully-stationary stretch so a stuck/false-connected
        //    reading can't keep a trip running indefinitely.
        if stationaryMin >= stationaryHardCapMinutes {
            log.log(String(format: "AUDIT: hard cap — stationary %.0f min (>= %.0f) — ending trip.",
                           stationaryMin, stationaryHardCapMinutes), level: .info)
            endTrip(reason: "stationary hard cap \(Int(stationaryMin)) min")
            return
        }

        // --- Heartbeat (with velocity + GPS health for diagnostics) -------
        let secsSinceGPS = Int(Date().timeIntervalSince(lastLocationAt))
        let gpsHealth: String
        if lastLocationAt == .distantPast {
            gpsHealth = "GPS none yet"
        } else {
            gpsHealth = String(format: "GPS %ds ago · acc %.0f m", secsSinceGPS, max(0, lastAccuracy))
        }
        let btState = hasPairing ? (btPresent ? "connected" : "missing(\(consecutiveBTMisses))") : "none"
        log.log(String(format: "AUDIT heartbeat: %.1f km · v %.0f km/h · %.0f min since movement · BT %@ · %@ · keep-alive(%@)",
                       trip.distanceKm,
                       trip.lastSpeedKmh,
                       stationaryMin,
                       btState,
                       gpsHealth,
                       connected ? "BT" : (recentlyMoving ? "moving" : "—")))
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

        // Pull the saved trip back out and resurrect it as the active state.
        store.trips.removeAll { $0.id == lastTrip.id }
        store.save()
        if let supabase = store.supabaseService {
            let id = lastTrip.id
            Task { try? await supabase.deleteTrip(id: id) }
        }

        let resumed = ActiveTripState(
            id: lastTrip.id,                                       // keep id for any external refs
            vehicleID: vehicle.id,
            audioDeviceUID: device?.uid,
            audioDeviceName: device?.name,
            startedAt: lastTrip.startedAt,                          // keep original start time
            startLat: endLat,
            startLng: endLng,
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
        consecutiveBTMisses = 0
        pendingSwitchVehicleID = nil
        pendingSwitchFirstSeenAt = nil

        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        startAuditTimer()
        return true
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

    /// Detects when the phone has connected to a DIFFERENT known vehicle's
    /// Bluetooth while a trip for the CURRENT vehicle is still active — e.g.
    /// the user parked car A, walked into car B, and car B's paired BT
    /// connected. Without this check, the Phase 12 "keep trip alive while
    /// moving" rule silently attributes car B's entire drive to car A,
    /// because motion alone was treated as sufficient justification to keep
    /// ANY trip open, regardless of which car is actually being driven.
    ///
    /// Requires the new vehicle's BT to be seen consistently for
    /// `switchConfirmSeconds` before acting (see debounce comment above) —
    /// adversarial review found that a single-read trigger here, while the
    /// symmetric BT-loss check uses a 3-strike debounce, made this check
    /// more trigger-happy than the disconnect logic it was meant to
    /// complement, risking exactly the kind of trip fragmentation /
    /// silent distance loss this whole feature exists to prevent.
    ///
    /// Ends the current trip immediately (using its last known point as the
    /// transition point) and starts a fresh one for the newly-detected
    /// vehicle, WITHOUT allowing that new trip to merge into an older saved
    /// trip (a detected switch is by definition a discontinuous event —
    /// resurrecting an unrelated earlier trip would misattribute distance
    /// and back-date its start time). Returns true if it acted, so callers
    /// can bail out of whatever they were doing with the now-stale trip
    /// reference.
    @discardableResult
    private func checkVehicleSwitch() -> Bool {
        guard let trip = activeTrip else { return false }
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

        guard let newVehicle = matchVehicle(for: currentDevice), newVehicle.id != trip.vehicleID else {
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
        // NOTE: stationary-based trip ending is intentionally NOT done here.
        // A naive per-update time check ("minutes since movement >= timeout
        // → end trip") used to live in this spot, but it ignored Bluetooth
        // connection state entirely. GPS multipath/jitter routinely produces
        // a spurious position update even while parked with the engine
        // idling (e.g. waiting at a light), and if one landed after the
        // timeout had elapsed, that old code ended the trip even though the
        // car's Bluetooth was still connected — directly contradicting the
        // "keep the trip alive while connected or moving" policy documented
        // on auditActiveTrip(). All stationary-based ending now goes through
        // auditActiveTrip() exclusively, which is BT-aware. The audit timer
        // (60s cadence) plus the fact that CLLocationManager simply doesn't
        // call this method while genuinely stationary (no update exceeds
        // distanceFilter) means centralizing here costs at most ~60s of
        // extra detection latency against a multi-minute timeout — an
        // acceptable trade for removing a source of incorrect early endings.
    }

    // MARK: - Trip end

    private func endTrip(reason: String) {
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
            consecutiveBTMisses = 0
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
            endedAt: Date(),
            startAddress: "",
            endAddress: "",
            distanceKm: state.distanceKm,
            notes: "Auto-detected",
            isLocked: false
        )
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
        consecutiveBTMisses = 0
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

    // MARK: - Audio route changes (BT disconnect ends the trip)

    @objc nonisolated private func audioRouteChanged(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.log("Audio route change: \(reason)")
            guard self.activeTrip != nil else { return }

            // Immediate vehicle-switch check — a new car's Bluetooth becoming
            // the active route is exactly what .newDeviceAvailable means, so
            // we don't wait for the next 60s audit tick to notice the swap.
            if reason == .newDeviceAvailable, self.checkVehicleSwitch() {
                return
            }

            // We no longer end the trip directly here on disconnect. A route
            // change (even .oldDeviceUnavailable) is frequently transient
            // with CarPlay, and ending immediately cut real drives short.
            // Instead, run a full audit pass: it applies the 3-strike
            // debounce AND the keep-alive-while-moving rule, so the trip
            // only ends when truly disconnected and stationary.
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

        // 2. Restore in-progress trip and resume GPS + audit so the trip
        //    end (BT disconnect or stationary) can still be detected.
        guard let data = try? Data(contentsOf: activeTripURL),
              let trip = try? JSONDecoder().decode(ActiveTripState.self, from: data) else { return }
        activeTrip = trip
        log.log("Restored in-progress trip after relaunch; resumed GPS and audit.", level: .info)

        manager.allowsBackgroundLocationUpdates = true
        store.settings.energyMode.apply(to: manager)
        manager.startUpdatingLocation()
        startAuditTimer()
    }
}

extension TripDetector: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.permission = status
            self.log.log("Location authorization changed: \(status.label)")
            if status == .authorizedAlways && self.store.settings.autoDetectEnabled && !self.isEnabled {
                self.startMonitoring()
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
    /// Power energy mode. This does NOT end the trip unconditionally: it
    /// defers to auditActiveTrip(), which is BT-aware. A car stopped at a
    /// long light with Bluetooth still connected must stay open even though
    /// iOS has paused GPS — ending here regardless of BT state would
    /// reintroduce the exact bug fixed by removing the old checkStationary().
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
