#if os(macOS)
import Foundation

/// Privacy a dropped connection held (#941): where it was, its Hello claims (nil when unknown) and when it was parked.
/// Unlike a parked mode it has no expiry, since privacy has none (Mick, round 2), and it is never consumed by a start:
/// while it is held, every fresh ambient stream on any connection starts private (the claims and its age are logged,
/// never compared), until the owner's own privacy-off clears it. In RAM only, so a haild restart restores nothing.
struct ParkedPrivacy: Sendable {
    let connection: UUID
    let device: AmbientPeerDevice?
    let parkedAt: Date
}

/// #941: privacy survives a transport drop. A private connection's teardown parks its privacy, and every fresh ambient
/// stream starts private while it is held, until the owner's own privacy-off (voice exit or app switch) clears it.
/// It only ever makes a stream quieter, so, as with the MM-E parks, unauthenticated Hello claims are never needed to
/// apply it. Logs ids, tokens, counts and booleans only, never words or device names.
extension AmbientRightyoRouter {
    /// Parks `connection`'s privacy under the caller's lock (`park`, from `stop(connection:device:)`), before teardown
    /// removes it, replacing any privacy parked before: the latest drop's claims are the ones logged.
    func parkPrivacy(connection: UUID, device: AmbientPeerDevice?, in state: inout State) {
        logLater("ambient_privacy_parked", connection: connection, detail: "replaced=\(state.parkedPrivacy != nil)")
        state.parkedPrivacy = ParkedPrivacy(connection: connection, device: device, parkedAt: configuration.now())
    }

    /// Carries parked privacy (#941) onto `connection`'s fresh stream, normal or `resume` alike, under the lock `start`
    /// takes before it makes the child, so the child is launched start-private (S-2b). Fail closed: while any privacy
    /// is parked, every start is private, whatever its claims or the park's age (both only logged), onto a connection
    /// not torn down and not already private. As a privacy entry does, under this one lock: the connection's own mode
    /// ends (never in both), the agent's replies are held (S-2c) and its pending ones dropped, and its device is told
    /// `duck_mode` on, with no reason. No clip. The park stays for the next start until the owner's off clears it.
    func restorePrivacy(to connection: UUID, in state: inout State) {
        guard let parked = state.parkedPrivacy, state.duck[connection] == nil,
              !state.closed.contains(connection) else { return }
        endHeld(connection, reason: "privacy", in: &state)
        state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
        let listener = state.listener?.value
        holdReplies(connection, listener: listener)
        let age = Self.seconds(configuration.now(), parked.parkedAt)
        mediaNotices.enqueue { [weak self, weak listener] in
            let here = await listener?.ambientPeerDevice(connection: connection)
            let match = AmbientPeerDevice.matches(here, parked.device)
            self?.emit("ambient_privacy_restored", connection: connection,
                       detail: "from=\(parked.connection) to=\(connection) device_match=\(match) age=\(age)")
            let sent = await listener?.showDuckMode(true, reason: "restored", expires: nil, connection: connection)
            self?.emit("ambient_duck_device", connection: connection,
                       detail: "on=true device=\(sent ?? "no_connection")")
        }
    }

    /// Whether a child made for `connection` may hear its stream (#941): not while privacy is parked and the connection
    /// is not private (privacy parked after its child was made public, or its restore lost to a teardown).
    static func admitsPrivacy(_ connection: UUID, in state: State) -> Bool {
        state.parkedPrivacy == nil || state.duck[connection] != nil
    }

    /// Clears parked privacy (#941) on the owner's own privacy-off, under the caller's lock: the only way it ends.
    func clearParkedPrivacy(in state: inout State) {
        guard state.parkedPrivacy != nil else { return }
        state.parkedPrivacy = nil
        logLater("ambient_park_discarded", detail: "reason=off mode=privacy")
    }
}
#endif
