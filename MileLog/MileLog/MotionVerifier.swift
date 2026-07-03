import Foundation
import CoreMotion

/// Wraps `CMMotionActivityManager` to expose a simple "is the user driving?"
/// signal. Used by `TripDetector` to filter out false trip starts that fire
/// when the user is walking, running or cycling — a frequent failure mode
/// before this gate was added.
@MainActor
final class MotionVerifier {

    private let manager = CMMotionActivityManager()
    private(set) var isMonitoring = false
    private(set) var hasAutomotiveSignal = false
    private(set) var hasNonAutomotiveSignal = false
    /// Timestamp of the most recent "automotive" classification, kept fresh
    /// for as long as monitoring runs (unlike `hasAutomotiveSignal`, which
    /// latches true once and never resets until `start()`). Used by
    /// `TripDetector` as a GPS-independent movement signal — the phone's
    /// accelerometer keeps working in a tunnel/underground garage where GPS
    /// goes dark, so a recent reading here means the car is very likely
    /// still being driven even though location updates have stopped arriving.
    private(set) var lastAutomotiveActivityAt: Date?

    /// Motion APIs crash the app instantly if NSMotionUsageDescription is
    /// missing from Info.plist. We refuse to call them in that case and let
    /// the detector fall back to speed-only verification.
    var isAvailable: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil else {
            return false
        }
        return CMMotionActivityManager.isActivityAvailable()
    }

    func start() {
        guard isAvailable, !isMonitoring else { return }
        hasAutomotiveSignal = false
        hasNonAutomotiveSignal = false
        lastAutomotiveActivityAt = nil
        isMonitoring = true

        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            // Ignore low-confidence guesses to avoid noise.
            guard activity.confidence != .low else { return }
            if activity.automotive {
                self.hasAutomotiveSignal = true
                self.lastAutomotiveActivityAt = Date()
            } else if activity.walking || activity.running || activity.cycling {
                self.hasNonAutomotiveSignal = true
            }
        }
    }

    func stop() {
        guard isMonitoring else { return }
        manager.stopActivityUpdates()
        isMonitoring = false
    }
}
