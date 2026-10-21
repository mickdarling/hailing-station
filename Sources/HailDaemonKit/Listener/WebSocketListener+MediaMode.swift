#if os(macOS)
import Foundation
import HailProtocol

extension WebSocketListener {
    /// Sends `media_mode` (#612) to the connection whose ambient stream it is: `sent`, `unsupported` (it did not
    /// advertise `media_mode`), `failed` or `no_connection`. Logged by the caller as tokens only.
    func showMediaMode(_ on: Bool, reason: String, expires: Int64?, connection: UUID) async -> String {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_connection"
        }
        guard let frame = await peer.session.mediaModeFrame(on, reason: reason, expires: expires) else {
            return "unsupported"
        }
        return await peer.post(frame) ? "sent" : "failed"
    }
}

extension HostSession {
    /// The owner's media mode state (#612) for a ready device that advertised `media_mode`; nil otherwise, since an
    /// older device refuses an unknown command. A reason outside the protocol's vocabulary is left off, and so is an
    /// expiry when the mode is off.
    func mediaModeFrame(_ on: Bool, reason: String, expires: Int64?) -> Frame? {
        guard case .ready(let version) = state, peerCapabilities.contains(MediaMode.capability) else { return nil }
        let expiry = on ? expires.flatMap { $0 > 0 ? $0 : nil } : nil
        return response(.mediaMode(on: on, reason: MediaMode.reason(reason), expires: expiry), version: version)
    }
}
#endif
