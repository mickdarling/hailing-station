#if os(iOS)
import AVFoundation
#endif
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
    /// Without capture, the shared category is still re-applied when it is the station's own play-and-record one,
    /// so capture-less reply playback follows the setting at once; the background keepalive's mixable playback
    /// category is left alone (#282, #352). A session that is ours is re-configured at once, then its input is
    /// re-resolved exactly like a route change: a saved owner choice still wins while it is selectable, and an HFP
    /// mic that is no longer allowed falls back to the next automatic input, so the mic is never left on a port the
    /// policy refuses. The app adds no override and no repair: the category change itself is never a hardware
    /// episode for the output-route repair (#879, #890), and any input re-selection is the one a route change makes.
    public func setAllowsBluetoothHFP(_ allows: Bool) async throws {
        guard preferences.allowsBluetoothHFP != allows else { return }
        preferences.allowsBluetoothHFP = allows
        guard wantsActive else {
            try await (backend as? any AudioSessionIdleConfiguring)?.configureIfStationOwned(allowsBluetoothHFP: allows)
            return
        }
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

/// A backend that can re-apply the category while no capture holds the session (#905).
protocol AudioSessionIdleConfiguring: Sendable {
    func configureIfStationOwned(allowsBluetoothHFP: Bool) async throws
}

enum AudioSessionIdleOwnership {
    /// Only the station's own play-and-record category is re-applied while idle. The keepalive's mixable playback,
    /// or a category nothing in the station has set yet, belongs to its owner and is never replaced (#282, #352).
    static func isStationOwned(_ category: AudioOutputRoutePolicy.Category, mixesWithOthers: Bool) -> Bool {
        category == .playAndRecord && !mixesWithOthers
    }
}

#if os(iOS)
extension AVAudioSessionBackend: AudioSessionIdleConfiguring {
    /// The shared session, as the reply player configures it; the production backend wraps the same instance.
    func configureIfStationOwned(allowsBluetoothHFP: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        let category: AudioOutputRoutePolicy.Category = session.category == .playAndRecord ? .playAndRecord : .other
        guard AudioSessionIdleOwnership.isStationOwned(
            category, mixesWithOthers: session.categoryOptions.contains(.mixWithOthers)
        ) else { return }
        try AudioOutputSessionRouting.configure(session, allowsBluetoothHFP: allowsBluetoothHFP)
    }
}
#endif
