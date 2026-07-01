import Foundation
import LocalAuthentication

/// Thin wrapper around LocalAuthentication for Face ID / Touch ID.
enum BiometricAuth {

    enum Kind {
        case faceID, touchID, none

        var label: String {
            switch self {
            case .faceID:  return "Face ID"
            case .touchID: return "Touch ID"
            case .none:    return "Biometrics"
            }
        }

        var systemImage: String {
            switch self {
            case .faceID:  return "faceid"
            case .touchID: return "touchid"
            case .none:    return "lock"
            }
        }
    }

    /// What biometry the device offers and has enrolled.
    static var available: Kind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        default:       return .none
        }
    }

    static var isAvailable: Bool { available != .none }

    /// Prompt the user. Uses `.deviceOwnerAuthentication` so that if Face ID
    /// fails (mask, repeated mismatch) the device passcode is offered as a
    /// fallback — important so the user can never get permanently locked out.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
