#if os(macOS)
public import Foundation

/// #904: a device re-asserts its privacy on a new connection before it resumes listening, so a drop while private (a
/// haild restart included, which parks nothing) never comes back public. The app sends `set_privacy` on before any
/// stream, waits for the `duck_mode` notice, and otherwise fails closed. Logs ids and tokens only, never words or
/// device
/// names.
extension AmbientRightyoRouter {
    /// `connection`'s pre-arm, handed on by the gate only while it has opened no stream (Jarvis R1): it becomes private
    /// as a restore leaves a connection (#941), so its first start, normal or `resume`, is launched start-private
    /// (`--start-private`, S-2b) and hears nothing before its private `started`. In RAM only, bound to the connection:
    /// its teardown parks it as any privacy (R2), and its own off is the owner's off. Like any privacy held, it makes
    /// every other connection's fresh start private, which fails closed; a stream already running elsewhere in public
    /// is
    /// left alone until it starts again (R3). Under one lock:
    /// - refused, logged `ambient_privacy_prearmed refused=<stopping|closed|streamed>`: haild stopping, the connection
    ///   torn down, or one that already started a stream (`latest`, or a run of it). A connection the gate already
    ///   ended never reaches here (`refused=ended`), and an arming for a device gone anyway is parked (`disarmIfGone`);
    /// - already private: nothing at all, as a switch that matches the state held (S-6);
    /// - privacy held elsewhere (another live connection, a park, or a park overflow, #961): taken exactly as
    ///   `restorePrivacy` takes it, with its heard state and its notice; logged `source=<live|park>`;
    /// - otherwise armed here, logged `source=none`: the connection's own mode ends (never in both), the agent's
    /// replies
    ///   are held and its pending ones dropped, and the device is told `duck_mode` on with reason `device`. No clip and
    ///   no announcement: a status answers nothing until privacy is announced (6362119223).
    public func ambientPrivacyPreArm(connection: UUID) {
        let outcome = state.withLock { state -> String? in
            guard state.duck[connection] == nil else { return nil }
            if state.shuttingDown || state.listener?.value == nil { return "refused=stopping" }
            if state.closed.contains(connection) { return "refused=closed" }
            if state.latest[connection] != nil || state.runs.values.contains(where: { $0.connection == connection }) {
                return "refused=streamed"
            }
            guard let (source, _) = Self.privacySource(except: connection, in: state) else {
                preArm(connection, in: &state)
                return "source=none"
            }
            restorePrivacy(to: connection, in: &state)
            return "source=\(source.token)"
        }
        guard let outcome else { return }
        emit("ambient_privacy_prearmed", connection: connection, detail: outcome)
    }

    /// A pre-arm the gate refused, logged as the router's own refusals are: `refused=ended` for a connection the gate
    /// already ended, so nothing is armed for it.
    public func ambientPrivacyPreArmRefused(connection: UUID, reason: String) {
        emit("ambient_privacy_prearmed", connection: connection, detail: "refused=\(reason)")
    }

    /// The backstop behind the gate's `ended` refusal (#967 second key): an arming (a pre-arm's or a restore's) whose
    /// `duck_mode` notice found no connection is for a device already gone, so it leaves the connection, only while it
    /// is still that arming (`token`), never a newer one. An unsourced pre-arm's (`park`) is parked first, by
    /// teardown's
    /// own `parkPrivacy` (Jarvis: privacy wins ties; the device may already hold its confirmation), so the next start
    /// anywhere restores it, private; a restore's is only dropped, since its park or live source is never consumed.
    /// Then the connection's privacy and its reply hold go, with a privacy ledger nothing
    /// announced on, as teardown drops them. Nothing else changes. Logged `ambient_privacy_disarmed
    /// reason=no_connection parked=<bool>`, beside the park's own `ambient_privacy_parked`.
    func disarmIfGone(_ connection: UUID, token: UUID, sent: String?, park: Bool = false) {
        guard sent == nil || sent == "no_connection" else { return }
        let (undone, parked) = state.withLock { state -> (Bool, Bool) in
            guard state.duck[connection]?.token == token else { return (false, false) }
            // The device's claims are gone with it (nil, unknown), as for any park whose claims were not read.
            if park { parkPrivacy(connection: connection, device: nil, in: &state) }
            state.duck[connection] = nil
            if state.privacy[connection]?.entries.isEmpty != false { state.privacy[connection] = nil }
            state.listener?.value?.replyHold.set(false, connection: connection)
            return (true, state.parks[connection]?.token == token)
        }
        guard undone else { return }
        emit("ambient_privacy_disarmed", connection: connection, detail: "reason=no_connection parked=\(parked)")
    }

    /// Arms `connection`'s privacy with no source, under the caller's lock, as `restorePrivacy` arms it from one.
    private func preArm(_ connection: UUID, in state: inout State) {
        endHeld(connection, reason: "privacy", in: &state)
        let token = UUID()
        state.duck[connection] = AmbientDuckTimer(token: token, timer: nil)
        let listener = state.listener?.value
        holdReplies(connection, listener: listener)
        mediaNotices.enqueue { [weak self, weak listener] in
            let sent = await listener?.showDuckMode(true, reason: "device", expires: nil, connection: connection)
            self?.emit("ambient_duck_device", connection: connection,
                       detail: "on=true device=\(sent ?? "no_connection")")
            self?.disarmIfGone(connection, token: token, sent: sent, park: true)
        }
    }
}
#endif
