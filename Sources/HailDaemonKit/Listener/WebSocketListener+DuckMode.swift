#if os(macOS)
public import Foundation
import HailProtocol
import Synchronization

/// A connection in duck mode (#735): the token an expiry must still match, and the task to cancel. Privacy arms no
/// timer (Mick, round 2: no auto-end), so `timer` is nil for it; the slot is kept for the session-mode auto-stop.
struct AmbientDuckTimer {
    let token: UUID
    let timer: Task<Void, Never>?
}

/// Privacy mode (#735, internally duck): entry from the owner's safety-set command, exit and status from RightyO's
/// content-free events, and its device notice (no auto-end, Mick round 2). The state lives beside media mode's in
/// `AmbientRightyoRouter.State`; `setDuck` changes it.
extension AmbientRightyoRouter {
    /// An hour. Reserved for the session-mode auto-stop: privacy has no auto-end (Mick, round 2), so this no longer
    /// applies to it. host.json `ambient.duckTimeout` overrides it.
    public static let defaultDuckTimeout: TimeInterval = 3600
    /// The `ambient.duckTimeout` values `haild` accepts, in seconds: a minute to four hours.
    public static let duckTimeoutRange: ClosedRange<TimeInterval> = 60...(4 * 3600)

    /// Privacy mode's commands (#735 S-2) for every child of `connection` at once, each confirmed with a clip when
    /// there is one, in the order said:
    /// - `enter`: `setDuck(true)`, which only a child that advertised `duck` v2 takes. Taken, or already on ("still
    ///   on"), it plays `confirm-privacy-on/`. Taken by none while off
    ///   (a v1 RightyO, which still transcribes, or no control descriptor) it is refused, fail closed: privacy stays
    ///   off and `confirm-not-sent/` plays, logged `refused=unsupported_version`. Taken or still on, a reply playing on
    ///   the connection is stopped first, as the owner's stop does (`playback=` in the log), then only the clip plays;
    ///   "still on" silences too, since nothing should be playing while private. A refused entry leaves playback alone.
    /// - `exit`: `setDuck(false)`, which tells the device, then `confirm-privacy-off/`. RightyO checked the owner. An
    ///   exit while privacy is off (a stale one released after the off, or a duplicate) is ignored: no `setDuck`, no
    ///   device notice and no clip, logged `ambient_privacy exit=ignored state=off`.
    /// - `status`: `confirm-privacy-status/` while privacy is on; nothing otherwise (S-3 answers every mode).
    /// - `stillRecording`: `confirm-still-recording/` only; nothing changes.
    /// - `refused`: an entry phrase from anyone but the owner: nothing changes (media mode included), no clip (S-5
    ///   may add one), logged `refused=not_owner`.
    /// - `unverified`: the owner role's entry without a live voiceprint: nothing changes, but `confirm-privacy-refused/`
    ///   (or `confirm-not-sent/`) says so, logged `refused=unverified_owner`.
    /// - `hint`: the owner's turn that starts with a command and goes on: held back, nothing changes, and
    ///   `confirm-privacy-hint/` ("To go private, say 'stop recording' on its own.") says how, logged `hint`.
    /// - `unavailable`: a child that cannot keep privacy was refused (`duckUnsupported`); privacy stays on, and
    ///   `confirm-privacy-unavailable/` ("I can't listen privately right now.") says so at most once per connection.
    /// Nothing reaches the agent. Logs tokens only.
    func voiceDuck(on connection: UUID, listener: WebSocketListener) -> @Sendable (PrivacyCommand) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] command in
            var (reported, on) = (0, false)
            if let self {
                if command == .exit, !duckMode(connection: connection) {
                    emit("ambient_privacy", connection: connection, detail: "exit=ignored state=off")
                    return
                }
                if command == .enter || command == .exit {
                    reported = setDuck(command == .enter, connection: connection, reason: "voice")
                }
                on = duckMode(connection: connection)
            }
            chain.enqueue { [weak self, weak listener, reported, on] in
                var (persona, outcome) = Self.duckConfirmation(command, reported: reported, on: on)
                if command == .unavailable, !Self.firstUnavailable(on: connection) {
                    (persona, outcome) = (nil, "unavailable repeat")
                }
                // Privacy taken (or still on) silences a reply playing on this connection first (Mick, round 2),
                // through the owner's stop path; a refused entry leaves playback alone.
                if command == .enter, on {
                    let playback = await listener?.stopReplyPlayback(connection: connection)
                    outcome += " playback=\(playback ?? "no_connection")"
                }
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
        case .unavailable: (AmbientStopConfirmation.privacyUnavailable, "unavailable")
        case .refused: (nil, "refused=not_owner")
        case .unverified: (AmbientStopConfirmation.privacyRefused, "refused=unverified_owner")
        case .hint: (AmbientStopConfirmation.privacyHint, "hint")
        }
    }

    /// A child that started while privacy was wished for without advertising `duck` v2 (an older RightyO after a
    /// reload) cannot keep it. Privacy is never ended for it (Mick, round 4: only the owner's exit ends privacy): when
    /// the host is still private this returns true and the pipeline refuses the child, so nothing records; logged
    /// `ambient_privacy child=unsupported_version kept=true`. False when privacy already ended: the child runs on.
    func duckUnsupported(on connection: UUID) -> @Sendable () -> Bool {
        { [weak self] in
            guard let self, duckMode(connection: connection) else { return false }
            emit("ambient_privacy", connection: connection, detail: "child=unsupported_version kept=true")
            return true
        }
    }

    /// Whether `unavailable` may still be said on `connection`: true once per connection, bounded in memory.
    static func firstUnavailable(on connection: UUID) -> Bool {
        unavailableSaid.withLock { said in
            guard !said.contains(connection) else { return false }
            said.append(connection)
            if said.count > 256 { said.removeFirst(said.count - 256) }
            return true
        }
    }
}

/// Connections already told privacy is unavailable (`firstUnavailable`); ids only, at most 256.
private let unavailableSaid = Mutex<[UUID]>([])

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
