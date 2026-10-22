#if os(macOS)
public import Foundation
import HailProtocol

/// A connection's duck mode timeout (#735): the token an expiry must still match, and the task to cancel.
struct AmbientDuckTimer {
    let token: UUID
    let timer: Task<Void, Never>
}

/// Duck mode (#735, "let me think out loud"): the owner's spoken entry and exit, its auto-end, and its device notice.
/// The state lives beside media mode's in `AmbientRightyoRouter.State`; `setDuck` changes it.
extension AmbientRightyoRouter {
    /// Three hours, as for media mode: a long think never ends mid-thought, and duck mode never outlasts an evening
    /// unnoticed. The auto-end is Mick's to choose (decision 3 of #735): host.json `ambient.duckTimeout` overrides it.
    public static let defaultDuckTimeout: TimeInterval = 3 * 3600
    /// The `ambient.duckTimeout` values `haild` accepts, in seconds: a minute to twelve hours.
    public static let duckTimeoutRange: ClosedRange<TimeInterval> = 60...(12 * 3600)

    /// The owner's spoken duck mode (#735): set for every child of `connection` at once, then confirmed with a
    /// `confirm-duck-on/` or `confirm-duck-off/` clip when there is one, in the order said. An entry no child took (an
    /// older RightyO, which would go on deciding turns) leaves duck mode off and plays `confirm-not-sent/`, as does an
    /// entry refused on an anonymous session; an exit no child took is not confirmed. Logs tokens only.
    func voiceDuck(on connection: UUID, listener: WebSocketListener) -> @Sendable (VoiceDuckCommand) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] command in
            let reported = command == .refused ? 0 : self?.setDuck(command == .on, connection: connection,
                                                                    reason: "voice") ?? 0
            chain.enqueue { [weak self, weak listener] in
                let (persona, outcome) = Self.duckConfirmation(command, reported: reported)
                var confirm = "unreported"
                if let persona {
                    confirm = await self?.confirmVoiceMute(persona, on: connection, listener: listener) ?? "none"
                }
                self?.emit("ambient_duck_confirmed", connection: connection, detail: "\(outcome) confirm=\(confirm)")
            }
        }
    }

    /// The clip folder that answers a duck mode phrase, or nil for none, and the log token for what happened.
    static func duckConfirmation(_ command: VoiceDuckCommand, reported: Int) -> (String?, String) {
        switch command {
        case .refused: (AmbientStopConfirmation.notSent, "on=true refused=anonymous")
        case .on where reported == 0: (AmbientStopConfirmation.notSent, "on=true refused=unsupported")
        case .on: (AmbientStopConfirmation.duckOn, "on=true")
        case .off: (reported > 0 ? AmbientStopConfirmation.duckOff : nil, "on=false")
        }
    }
}

extension WebSocketListener {
    /// Sends `duck_mode` (#735) to the connection whose ambient stream it is: `sent`, `unsupported` (it did not
    /// advertise `duck_mode`), `failed` or `no_connection`. Logged by the caller as tokens only.
    func showDuckMode(_ on: Bool, reason: String, expires: Int64?, connection: UUID) async -> String {
        guard !stopped, let peer = peers.values.first(where: { $0.session.connectionID == connection }) else {
            return "no_connection"
        }
        guard let frame = await peer.session.duckModeFrame(on, reason: reason, expires: expires) else {
            return "unsupported"
        }
        return await peer.post(frame) ? "sent" : "failed"
    }
}

extension HostSession {
    /// The owner's duck mode state (#735) for a ready device that advertised `duck_mode`; nil otherwise, since an
    /// older device refuses an unknown command. A reason outside the protocol's vocabulary is left off, and so is an
    /// expiry when the mode is off.
    func duckModeFrame(_ on: Bool, reason: String, expires: Int64?) -> Frame? {
        guard case .ready(let version) = state, peerCapabilities.contains(DuckMode.capability) else { return nil }
        let expiry = on ? expires.flatMap { $0 > 0 ? $0 : nil } : nil
        return response(.duckMode(on: on, reason: DuckMode.reason(reason), expires: expiry), version: version)
    }
}
#endif
