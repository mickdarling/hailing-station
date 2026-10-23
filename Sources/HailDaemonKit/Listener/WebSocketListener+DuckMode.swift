#if os(macOS)
public import Foundation
import HailProtocol

/// A connection in duck mode (#735): the token an expiry must still match, and the task to cancel. Privacy arms no
/// timer (Mick, round 2: no auto-end), so `timer` is nil for it; the slot is kept for the session-mode auto-stop.
struct AmbientDuckTimer {
    let token: UUID
    let timer: Task<Void, Never>?
}

/// Privacy mode (#735, internally duck): entry from the owner's safety-set command, exit and status from RightyO's
/// content-free events, the app's privacy switch (S-6), and its device notice (no auto-end, Mick round 2). The state
/// lives beside media mode's in `AmbientRightyoRouter.State`; `setDuck` changes it.
extension AmbientRightyoRouter {
    /// An hour. Reserved for the session-mode auto-stop: privacy has no auto-end (Mick, round 2), so this no longer
    /// applies to it. host.json `ambient.duckTimeout` overrides it.
    public static let defaultDuckTimeout: TimeInterval = 3600
    /// The `ambient.duckTimeout` values `haild` accepts, in seconds: a minute to four hours.
    public static let duckTimeoutRange: ClosedRange<TimeInterval> = 60...(4 * 3600)

    /// Privacy mode's commands (#735 S-2) for every child of `connection` at once, each confirmed with a clip when
    /// there is one, in the order said:
    /// - `enter`: `setDuck(true)`, which only a child that advertised `duck` v3 takes. Taken, or already on ("still
    ///   on"), it is announced by `announceEntry` (S-8 HS-C): `confirm-privacy-on/` once every child proved it keeps
    ///   privacy, else `confirm-privacy-unavailable/` (logged `unacknowledged`, `refused`, `ended` or `timeout`), each
    ///   after a reply playing is stopped (`playback=` in the log); withdrawn first, nothing (`withdrawn`). Taken by
    ///   none while off (a v1 RightyO, which still transcribes, or no control descriptor) it is refused, fail closed:
    ///   privacy stays off and `confirm-not-sent/` plays, logged `refused=unsupported_version`; playback is left alone.
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
    ///   `confirm-privacy-unavailable/` ("I can't listen privately right now.") says so every time (#822 A), except for
    ///   a child a reload already retired (`retired`), whose stream lives on in its successor: logged, in silence; and
    ///   except while the entry it is attributed to is open (`mark`'s child): that entry says it, so it is said once.
    /// Nothing reaches the agent. Logs tokens only.
    func voiceDuck(on connection: UUID, listener: WebSocketListener,
                   retired: @escaping @Sendable () -> Bool = { false },
                   mark: AmbientRunMark? = nil) -> @Sendable (PrivacyCommand) -> Void {
        let chain = SerialTaskChain()
        return { [weak self, weak listener] command in
            var (reported, on, entry) = (0, false, AmbientPrivacyEntry?.none)
            // Read now, while the refused child's run is still registered: once it ends, the router removes it.
            let silent = command == .unavailable && retired()
            if command == .unavailable, !silent, mark?.pipeline?.takePrivacyAnnouncement() == false { return }
            if let self {
                if command == .exit, !duckMode(connection: connection) {
                    emit("ambient_privacy", connection: connection, detail: "exit=ignored state=off")
                    return
                }
                if command == .enter || command == .exit {
                    entry = switchDuck(command == .enter, connection: connection, reason: "voice") { _ in true }
                    reported = entry?.reported ?? 0
                }
                on = duckMode(connection: connection)
            }
            chain.enqueue { [weak self, weak listener, reported, on, silent, entry] in
                var (persona, outcome) = Self.duckConfirmation(command, reported: reported, on: on)
                if silent { (persona, outcome) = (nil, "unavailable retired") }
                // Bounded by `privacyConfirmTimeout`, so the chain never waits forever.
                if let entry, entry.entry != nil, let self {
                    let (clip, tokens) = await announceEntry(entry, connection: connection, listener: listener)
                    (persona, outcome) = (clip, "on=true" + tokens)
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
    /// how many children took it and whether privacy is on afterwards. An entry taken or still on is announced by
    /// `announceEntry` instead, once its children answered (#735 S-8 HS-C).
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

    /// The app's privacy switch (#735 S-6, `set_privacy`) for `connection`, the sending session's own: the gate hands
    /// it on only while that connection holds the active ambient stream. Trust is the paired owner device (Mick's
    /// decision), not a voice, so no voiceprint is asked for. A switch that matches the state already held does nothing
    /// at all: nothing is logged, written, played or sent back, so repeated taps cannot flood the log or chatter.
    public func ambientPrivacy(_ on: Bool, connection: UUID) {
        let armed = duckArming(connection: connection)
        guard on == (armed == nil) else { return }
        switchPrivacy(on, connection: connection, armedAs: armed)
    }

    /// Switches `connection`'s privacy from its device, only while its arming is still `armed` (nil: off), matched under
    /// the lock that changes it. If the owner's voice changed it since it was read, this does nothing: no second
    /// notice wrongly saying `device`, no child write, no log line and no clip.
    /// - on: the owner's entry path with reason `device`. `setDuck(true)` writes the children (so a respawn or reload
    ///   starts private, S-2b), holds every request back and tells the device once a child took it; then it is
    ///   announced as the voice entry is (`announceEntry`, S-8 HS-C). Taken by no child (a v1 or older
    ///   RightyO), it fails closed: privacy stays off, the device is told off so its switch settles on not private,
    ///   `confirm-not-sent/` plays, and playback is left alone.
    /// - off: the owner's exit path with reason `device`. `setDuck(false)` tells the children and the device, then
    ///   `confirm-privacy-off/` plays when a child took it.
    /// Logged as state tokens only.
    func switchPrivacy(_ on: Bool, connection: UUID, armedAs armed: UUID?) {
        guard let entry = switchDuck(on, connection: connection, reason: "device", whileArming: { $0 == armed }) else {
            return
        }
        let listener = attachedListener
        privacySwitches.enqueue { [weak self, weak listener] in
            guard let self else { return }
            var (persona, outcome): (String?, String) = (nil, "on=\(on) reason=device")
            switch (on, entry.reported > 0) {
            case (true, true):
                let (clip, tokens) = await announceEntry(entry, connection: connection, listener: listener)
                (persona, outcome) = (clip, outcome + tokens)
            case (true, false):
                let device = await listener?.showDuckMode(false, reason: "device", expires: nil,
                                                          connection: connection) ?? "no_connection"
                persona = AmbientStopConfirmation.notSent
                outcome += " refused=unsupported_version device=\(device)"
            case (false, true): persona = AmbientStopConfirmation.privacyOff
            case (false, false): break
            }
            var confirm = "unreported"
            if let persona { confirm = await confirmVoiceMute(persona, on: connection, listener: listener) }
            emit("ambient_duck_confirmed", connection: connection, detail: "\(outcome) confirm=\(confirm)")
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
