import Foundation
import Combine

/// Optional Face ID / Touch ID lock on top of the normal Supabase sign-in.
/// The preference is stored in UserDefaults (device-local) — biometric choice
/// is a per-device security setting and intentionally NOT synced to the cloud.
@MainActor
final class AppLock: ObservableObject {

    /// True while the app content should be hidden behind the lock screen.
    @Published private(set) var isLocked: Bool

    /// Whether the user has turned the biometric lock on.
    @Published private(set) var enabled: Bool

    private static let key = "biometricLockEnabled"

    init() {
        let on = UserDefaults.standard.bool(forKey: Self.key)
        enabled = on
        // Start locked if the feature is on, so a cold launch requires auth.
        isLocked = on
    }

    /// Lock now (called when the app goes to the background).
    func lock() {
        if enabled { isLocked = true }
    }

    /// Attempt to unlock via biometrics / passcode.
    func unlock() async {
        guard enabled else { isLocked = false; return }
        let ok = await BiometricAuth.authenticate(reason: "Unlock MileLog")
        if ok { isLocked = false }
    }

    /// Turn the lock on — requires a successful auth first so the user can't
    /// enable a lock they can't pass. Returns whether it was enabled.
    @discardableResult
    func enable() async -> Bool {
        let ok = await BiometricAuth.authenticate(
            reason: "Confirm \(BiometricAuth.available.label) to protect MileLog"
        )
        if ok {
            enabled = true
            isLocked = false
            UserDefaults.standard.set(true, forKey: Self.key)
        }
        return ok
    }

    /// Turn the lock off.
    func disable() {
        enabled = false
        isLocked = false
        UserDefaults.standard.set(false, forKey: Self.key)
    }
}
