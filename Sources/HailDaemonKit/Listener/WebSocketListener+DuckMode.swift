#if os(macOS)
public import Foundation
import HailProtocol

/// A connection's duck mode timeout (#735): the token an expiry must still match, and the task to cancel. `warning`
/// (H-4) plays the auto-end warning a minute before; nil when the timeout is too short for one.
struct AmbientDuckTimer {
    let token: UUID
    let timer: Task<Void, Never>
    var warning: Task<Void, Never>?

    /// Cancels the auto-end and its warning together, so a warning never outlives the arming it belongs to.
    func cancel() {
        timer.cancel()
        warning?.cancel()
    }
}

/// Duck mode (#735, "let me think out loud"): the owner's spoken entry and exit, its auto-end, and its device notice.
/// The state lives beside media mode's in `AmbientRightyoRouter.State`; `setDuck` changes it.
extension AmbientRightyoRouter {
    /// An hour (provisional default for decision 3 of #735, Mick's to change): long enough for one think, short
    /// enough that a forgotten duck mode does not swallow the evening. host.json `ambient.duckTimeout` overrides it.
    public static let defaultDuckTimeout: TimeInterval = 3600
    /// The `ambient.duckTimeout` values `haild` accepts, in seconds: a minute to four hours.
    public static let duckTimeoutRange: ClosedRange<TimeInterval> = 60...(4 * 3600)
    /// How long before the auto-end the owner hears `confirm-duck-ending/` (#735 H-4): a minute, enough to say the
    /// entry again (which re-arms it) or wrap up. A timeout no longer than this has no warning.
    static let defaultDuckWarningLead: TimeInterval = 60

    /// The owner's spoken duck mode (#735): set for every child of `connection` at once, then confirmed with a
    /// `confirm-duck-on/` or `confirm-duck-off/` clip when there is one, in the order said. An entry while duck mode is
    /// already on is answered "still on" with `confirm-duck-on/` (worded as a status), the auto-end re-armed when a
    /// child took it. An entry no child took while duck mode is off (an older RightyO, which would go on deciding
    /// turns) leaves it off and plays `confirm-not-sent/`, as does a phrase refused on an anonymous session; an exit
    /// no child took is not confirmed. Logs tokens only.
    func voiceDuck(on connection: UUID, listener: WebSocketListener) -> @Sendable (VoiceDuckCommand) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] command in
            var (reported, on) = (0, false)
            if command == .on || command == .off, let self {
                reported = setDuck(command == .on, connection: connection, reason: "voice")
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

    /// The clip folder that answers a duck mode phrase, or nil for none, and the log token for what happened, given
    /// how many children took it and whether duck mode is on afterwards.
    static func duckConfirmation(_ command: VoiceDuckCommand, reported: Int, on: Bool) -> (String?, String) {
        switch command {
        case .refused(let entry): (AmbientStopConfirmation.notSent, "on=\(entry) refused=anonymous")
        case .on where reported == 0 && on: (AmbientStopConfirmation.duckOn, "on=true still_on")
        case .on where reported == 0: (AmbientStopConfirmation.notSent, "on=true refused=unsupported")
        case .on: (AmbientStopConfirmation.duckOn, "on=true")
        case .off: (reported > 0 ? AmbientStopConfirmation.duckOff : nil, "on=false")
        }
    }

    /// A child that started while duck mode was on without advertising `duck` (an older RightyO after a reload) cannot
    /// take it, and the host never claims a mode a child is not in: duck mode ends for `connection`, its timeout is
    /// cancelled and the device told off. The device's reason is `timeout`, the protocol's "it turned itself off":
    /// nobody asked (`voice` and `device` would both say someone did); the host log says why.
    func duckUnsupported(on connection: UUID) -> @Sendable () -> Void {
        { [weak self] in
            guard let self, duckMode(connection: connection) else { return }
            emit("ambient_duck_unsupported", connection: connection, detail: "child=started_without_duck")
            setDuck(false, connection: connection, reason: "timeout")
        }
    }
}

extension AmbientRightyoRouter {
    /// The owner's duck cue (#735 H-3), confirmed in the order said: "discard that" with a `confirm-discarded/` clip,
    /// an ask nothing could send with `confirm-not-sent/`. A sent ask needs no clip of its own: the ordinary
    /// acknowledgement already played, and the agent's reply follows. The status cue ("are you still listening") is
    /// answered by the host with `confirm-duck-on/` ("Duck mode is on.", H-4), never by the agent: nothing is
    /// dispatched, so a long silence never looks like a failure. Logs counts and tokens only, never words.
    func duckCue(on connection: UUID, listener: WebSocketListener) -> @Sendable (DuckCueOutcome) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] outcome in
            chain.enqueue { [weak self, weak listener] in
                let (persona, detail) = Self.duckCueConfirmation(outcome)
                var confirm = "none"
                if let persona {
                    confirm = await self?.confirmVoiceMute(persona, on: connection, listener: listener) ?? "none"
                }
                self?.emit("ambient_duck_cue", connection: connection, detail: "\(detail) confirm=\(confirm)")
            }
        }
    }

    /// The clip folder that answers a duck cue, or nil for none, and the log token for what happened.
    static func duckCueConfirmation(_ outcome: DuckCueOutcome) -> (String?, String) {
        switch outcome {
        case .asked(let turns, let bytes): (nil, "cue=ask outcome=sent turns=\(turns) bytes=\(bytes)")
        case .notSent: (AmbientStopConfirmation.notSent, "cue=ask outcome=not_sent")
        case .discarded(let turns): (AmbientStopConfirmation.discarded, "cue=discard turns=\(turns)")
        case .status: (AmbientStopConfirmation.duckOn, "cue=status outcome=answered")
        }
    }
}

extension AmbientRightyoRouter {
    /// The auto-end warning for one arming of duck mode (#735 H-4), or nil when `timeout` is no longer than the lead:
    /// after `timeout` less the lead it plays `confirm-duck-ending/` on `connection`, only if that same arming is still
    /// on and a child of the connection runs. Cancelled with the auto-end (`AmbientDuckTimer.cancel`), so an exit, a
    /// re-entry, media mode or the connection's end before then means no warning; a re-entry arms a fresh one.
    func duckWarning(connection: UUID, token: UUID, timeout: TimeInterval,
                     listener: WebSocketListener?) -> Task<Void, Never>? {
        let lead = configuration.duckWarningLead
        guard lead > 0, timeout > lead else { return nil }
        return Task { [weak self, weak listener] in
            try? await Task.sleep(for: .seconds(timeout - lead))
            guard !Task.isCancelled, let self, duckArmed(connection: connection, token: token) else { return }
            let confirm = await confirmVoiceMute(AmbientStopConfirmation.duckEnding, on: connection, listener: listener)
            emit("ambient_duck_ending", connection: connection, detail: "confirm=\(confirm)")
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
