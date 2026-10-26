public import Foundation

/// The owner's "Use AirPods / Bluetooth headset microphone" setting (#905). Off by default: HFP puts AirPods in
/// call mode, which lowers their audio to mono call quality while it is in use.
public protocol AudioBluetoothHFPConfiguring: Sendable {
    func setAllowsBluetoothHFP(_ allows: Bool) async throws
}

public extension AudioInputPreferences {
    /// Written by the station's settings toggle; read once when the station creates its audio session.
    static let bluetoothHFPDefaultsKey = "audio.allowsBluetoothHFP"

    /// The default order with the owner's saved Bluetooth headset microphone setting.
    static func saved(in defaults: UserDefaults = .standard) -> AudioInputPreferences {
        AudioInputPreferences(allowsBluetoothHFP: defaults.bool(forKey: bluetoothHFPDefaultsKey))
    }
}

extension ManagedAudioSession: AudioBluetoothHFPConfiguring {
    /// An inactive session, or one the background keepalive holds, is left alone: the next activation configures
    /// with the new setting. A session that is ours is re-configured at once, then its input is re-resolved exactly
    /// like a route change: a saved owner choice still wins while it is selectable, and an HFP mic that is no longer
    /// allowed falls back to the next automatic input, so the mic is never left on a port the policy refuses.
    /// The category change itself is never a hardware episode for the output-route repair, so it cannot undo an
    /// owner's route choice or spend an episode's single repair (#879, #890); any input re-selection is the same
    /// one a route change would make.
    public func setAllowsBluetoothHFP(_ allows: Bool) async throws {
        guard preferences.allowsBluetoothHFP != allows else { return }
        preferences.allowsBluetoothHFP = allows
        guard wantsActive else { return }
        var failure: (any Error)?
        do {
            try await backend.configure(allowsBluetoothHFP: allows)
        } catch {
            failure = error
        }
        // Even when iOS refuses the category, the input still follows the setting: a refused HFP mic is left.
        await handleRouteChange()
        if let failure { throw failure }
    }
}
