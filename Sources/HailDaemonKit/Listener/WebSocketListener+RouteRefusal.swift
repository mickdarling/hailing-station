#if os(macOS)
import Foundation
import HailProtocol

extension WebSocketListener {
    /// Tells the connection whose ambient stream it is that a request it addressed to a voice route was not sent
    /// (#636, slice 5c), or that one was not typed because the target's input already holds unsent text (#894), while
    /// it still selects the stream's `target`, as the clip that follows must: `sent`,
    /// `unsupported` (it did not advertise request refusals, and an older device ends its connection on any error, so
    /// it is told nothing), `not_ready` (no negotiated session, or it selects another target), `failed` or
    /// `no_connection`. Logged by the caller as tokens.
    func showRouteRefusal(_ message: String, target: String, connection: UUID) async -> String {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_connection"
        }
        guard await peer.session.peerCapabilities.contains(RequestRefusals.capability) else { return "unsupported" }
        guard let frame = await peer.session.routeRefusalFrame(message, target: target) else { return "not_ready" }
        return await peer.post(frame) ? "sent" : "failed"
    }
}

extension HostSession {
    /// `voice_route_refused` for a ready device that takes request refusals (#665) and still selects `target`: it ends
    /// that request only, and the device shows it as one chat line and one announcement (#692). Nil otherwise.
    func routeRefusalFrame(_ message: String, target: String) -> Frame? {
        guard case .ready(let version) = state, selectedTarget == target,
              peerCapabilities.contains(RequestRefusals.capability) else { return nil }
        return response(.error(code: .voiceRouteRefused, message: message), version: version)
    }
}
#endif
