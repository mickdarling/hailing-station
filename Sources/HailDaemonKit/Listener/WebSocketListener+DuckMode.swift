#if os(macOS)
public import Foundation
import HailProtocol

/// A connection's duck mode timeout (#735): the token an expiry must still match, and the task to cancel.
struct AmbientDuckTimer {
    let token: UUID
    let timer: Task<Void, Never>
}

/// Privacy mode (#735, internally duck): entry from any speaker's safety-set phrase, exit and status from RightyO's
/// content-free events, its auto-end and its device notice. The state lives beside media mode's in
/// `AmbientRightyoRouter.State`; `setDuck` changes it.
extension AmbientRightyoRouter {
    /// An hour (provisional default for decision 3 of #735, Mick's to change): long enough for one think, short
    /// enough that a forgotten privacy mode does not swallow the evening. host.json `ambient.duckTimeout` overrides it.
    public static let defaultDuckTimeout: TimeInterval = 3600
    /// The `ambient.duckTimeout` values `haild` accepts, in seconds: a minute to four hours.
    public static let duckTimeoutRange: ClosedRange<TimeInterval> = 60...(4 * 3600)

    /// Privacy mode's commands (#735 S-2) for every child of `connection` at once, each confirmed with a clip when
    /// there is one, in the order said:
    /// - `enter`: `setDuck(true)`, which only a child that advertised `duck` v2 takes. Taken, or already on ("still
    ///   on", the auto-end re-armed when a child took it), it plays `confirm-privacy-on/`. Taken by none while off
    ///   (a v1 RightyO, which still transcribes, or no control descriptor) it is refused, fail closed: privacy stays
    ///   off and `confirm-not-sent/` plays, logged `refused=unsupported_version`.
    /// - `exit`: `setDuck(false)`, which tells the device, then `confirm-privacy-off/`. RightyO checked the owner.
    /// - `status`: `confirm-privacy-status/` while privacy is on; nothing otherwise (S-3 answers every mode).
    /// - `stillRecording`: `confirm-still-recording/` only; nothing changes.
    /// Nothing reaches the agent. Logs tokens only.
    func voiceDuck(on connection: UUID, listener: WebSocketListener) -> @Sendable (PrivacyCommand) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] command in
            var (reported, on) = (0, false)
            if let self {
                if command == .enter || command == .exit {
                    reported = setDuck(command == .enter, connection: connection, reason: "voice")
                }
                on = duckMode(connection: connection)
            }
            chain.enqueue { [weak self, weak listener, reported, on] in
                let (persona, outcome) = Self.duckConfirmation(command, reported: reported, on: on)
                var confirm = "unreported"
                if let persona {
                    confirm = await self?.confirmVoiceMute(persona, on: connection, listener: listener) ?? "none"
                }
                self?.emit("ambient_duck_confirmed", connection: connection, detail: "\(outcome) confirm=\(confirm)")
            }
        }
    }

    /// The clip folder that answers a privacy command, or nil for none, and the log token for what happened, given
    /// how many children took it and whether privacy is on afterwards.
    static func duckConfirmation(_ command: PrivacyCommand, reported: Int, on: Bool) -> (String?, String) {
        switch command {
        case .enter where reported > 0: (AmbientStopConfirmation.privacyOn, "on=true")
        case .enter where on: (AmbientStopConfirmation.privacyOn, "on=true still_on")
        case .enter: (AmbientStopConfirmation.notSent, "on=true refused=unsupported_version")
        case .exit: (reported > 0 ? AmbientStopConfirmation.privacyOff : nil, "on=false")
        case .status: (on ? AmbientStopConfirmation.privacyStatus : nil, "status on=\(on)")
        case .stillRecording: (AmbientStopConfirmation.stillRecording, "negated")
        }
    }

    /// A child that started while privacy was on without advertising `duck` v2 (an older RightyO after a reload)
    /// cannot take it, and the host never claims a mode a child is not in: privacy ends for `connection`, its timeout
    /// is cancelled and the device told off. The device's reason is `timeout`, the protocol's "it turned itself off":
    /// nobody asked (`voice` and `device` would both say someone did); the host log says why.
    func duckUnsupported(on connection: UUID) -> @Sendable () -> Void {
        { [weak self] in
            guard let self, duckMode(connection: connection) else { return }
            emit("ambient_duck_unsupported", connection: connection, detail: "child=unsupported_version")
            setDuck(false, connection: connection, reason: "timeout")
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
