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
}
