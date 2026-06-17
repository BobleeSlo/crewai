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
        isMonitoring = true

        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            // Ignore low-confidence guesses to avoid noise.
            guard activity.confidence != .low else { return }
            if activity.automotive {
                self.hasAutomotiveSignal = true
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
