import Foundation
import AVFoundation

/// A Bluetooth audio device currently visible in the iOS audio route.
struct BluetoothAudioDevice: Equatable {
    let name: String
    let uid: String
}

/// Reads the active audio output route. The point is to detect which car-audio
/// device the iPhone is currently connected to, so the user can pair that
/// device with a vehicle for automatic trip detection (Phase 3b).
enum AudioRoute {

    /// Bluetooth output ports we care about (car kits + general BT audio).
    private static let bluetoothPorts: Set<AVAudioSession.Port> = [
        .bluetoothA2DP,
        .bluetoothHFP,
        .bluetoothLE,
        .carAudio
    ]

    /// Returns the first Bluetooth / car-audio output currently routed by iOS,
    /// or `nil` if the phone is using built-in speakers / headphones.
    static func currentBluetoothOutput() -> BluetoothAudioDevice? {
        // Reading currentRoute does not require activating the session.
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        for output in outputs where bluetoothPorts.contains(output.portType) {
            return BluetoothAudioDevice(name: output.portName, uid: output.uid)
        }
        return nil
    }

    /// True if a previously-paired car is *still connected*, even when it is
    /// not the active audio OUTPUT at this instant. CarPlay / Bluetooth audio
    /// frequently stop being the current output during quiet stretches (no
    /// music, no nav voice), which made a pure `currentBluetoothOutput()`
    /// check falsely report "BT missing" mid-drive. We therefore also scan
    /// the session's available inputs, where a connected car remains listed.
    static func isPairedDevicePresent(uid: String?, name: String?) -> Bool {
        guard uid != nil || (name?.isEmpty == false) else { return false }
        let session = AVAudioSession.sharedInstance()

        func matches(portUID: String, portName: String) -> Bool {
            if let uid, !uid.isEmpty, portUID == uid { return true }
            if let name, !name.isEmpty, portName == name { return true }
            return false
        }

        for output in session.currentRoute.outputs where bluetoothPorts.contains(output.portType) {
            if matches(portUID: output.uid, portName: output.portName) { return true }
        }
        if let inputs = session.availableInputs {
            for input in inputs where bluetoothPorts.contains(input.portType) {
                if matches(portUID: input.uid, portName: input.portName) { return true }
            }
        }
        return false
    }
}
