#if os(macOS)
import Foundation

/// Privacy a dropped connection held (#941): where it was, its arming (`token`), its Hello claims (nil when unknown),
/// when it was parked, and whether the owner had heard it announced there (`heardOn`), so a restored connection's status
/// answers the same. Unlike a parked mode it has no expiry, since privacy has none (Mick, round 2), and it is never
/// consumed by a start: while it is held, every fresh ambient stream on any connection starts private (the claims and
/// its age are logged), until the owner's own privacy-off clears it. In RAM only, so a haild restart restores nothing.
struct ParkedPrivacy: Sendable {
    let connection: UUID
    let device: AmbientPeerDevice?
    let parkedAt: Date
    var heard = false
    var token: UUID?
}

/// Another connection holding privacy when the owner turned it off elsewhere (#941): its arming then, and its claims.
struct PrivacyHolder: Sendable {
    let connection: UUID
    let token: UUID
    let device: AmbientPeerDevice?
}

/// #941: privacy survives a transport drop. Every fresh ambient stream starts private while any privacy is held
/// elsewhere: parked by a private connection's teardown, or still held by another live connection (haild has no
/// keepalive, so a dropped phone's old connection can outlive its reconnect, MM-E's `live` source). The owner's own
/// privacy-off (voice exit or app switch) clears the park and ends privacy on the same device's other connections. It
/// only ever makes a stream quieter, so, as with the MM-E parks, unauthenticated Hello claims are never needed to apply
/// it; they only scope an off, failing closed. Logs ids, tokens, counts and booleans only, never words or device names.
extension AmbientRightyoRouter {
    /// Parks `connection`'s privacy under the caller's lock (`park`, from `stop(connection:device:)`), before teardown
    /// removes it, replacing any privacy parked before: the latest drop's claims are the ones logged.
    func parkPrivacy(connection: UUID, device: AmbientPeerDevice?, in state: inout State) {
        logLater("ambient_privacy_parked", connection: connection, detail: "replaced=\(state.parkedPrivacy != nil)")
        state.parkedPrivacy = ParkedPrivacy(connection: connection, device: device, parkedAt: configuration.now(),
                                            heard: state.privacy[connection]?.heardOn == true,
                                            token: state.duck[connection]?.token)
    }

    /// Carries privacy (#941) onto `connection`'s fresh stream, normal or `resume` alike, under the lock `start` takes
    /// before it makes the child, so the child is launched start-private (S-2b). Fail closed: while any other
    /// connection holds privacy or a park is held, every start is private, whatever its claims or the park's age (both
    /// only logged), onto a connection not torn down and not already private. As a privacy entry does, under this one
    /// lock: the connection's own mode ends (never in both), the agent's replies are held (S-2c) and its pending ones
    /// dropped, and its device is told `duck_mode` on with reason `device` (its own start after a reconnect changed
    /// it; the protocol has no other fitting reason, and a device refuses an unknown one). No clip, but a status
    /// answers as it would where privacy was heard announced.
    func restorePrivacy(to connection: UUID, in state: inout State) {
        guard state.duck[connection] == nil, !state.closed.contains(connection),
              let (source, from) = Self.privacySource(except: connection, in: state) else { return }
        endHeld(connection, reason: "privacy", in: &state)
        state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
        if Self.privacyHeard(except: connection, in: state) {
            state.privacy[connection, default: .init()].carryHeard()
        }
        let listener = state.listener?.value
        holdReplies(connection, listener: listener)
        let age = state.parkedPrivacy.map { " age=\(Self.seconds(configuration.now(), $0.parkedAt))" } ?? ""
        mediaNotices.enqueue { [weak self, weak listener] in
            let here = await listener?.ambientPeerDevice(connection: connection)
            let match = AmbientPeerDevice.matches(here, await source.device(of: from, listener: listener))
            self?.emit("ambient_privacy_restored", connection: connection,
                       detail: "source=\(source.token) from=\(from) to=\(connection) device_match=\(match)"
                           + (source.token == "park" ? age : ""))
            let sent = await listener?.showDuckMode(true, reason: "device", expires: nil, connection: connection)
            self?.emit("ambient_duck_device", connection: connection,
                       detail: "on=true device=\(sent ?? "no_connection")")
        }
    }

    /// Where a fresh start's privacy comes from (#941): another live connection that holds it (one the owner heard
    /// announced first, then by id, so the log is stable), else the park; nil when there is none.
    static func privacySource(except connection: UUID, in state: State) -> (RestoreSource, UUID)? {
        let live = state.duck.keys.filter { $0 != connection }.sorted { $0.uuidString < $1.uuidString }
        if let holder = live.first(where: { state.privacy[$0]?.heardOn == true }) ?? live.first {
            return (.live, holder)
        }
        return state.parkedPrivacy.map { (.park($0.device), $0.connection) }
    }

    /// Whether the owner heard any of that privacy announced: a live holder's, or the park's.
    static func privacyHeard(except connection: UUID, in state: State) -> Bool {
        state.parkedPrivacy?.heard == true
            || state.duck.keys.contains { $0 != connection && state.privacy[$0]?.heardOn == true }
    }

    /// Whether a child made for `connection` may hear its stream (#941): only a private one while any other connection
    /// holds privacy or a park is held (privacy taken elsewhere after its child was made public, or its restore lost to
    /// a teardown).
    static func admitsPrivacy(_ connection: UUID, in state: State) -> Bool {
        state.duck[connection] != nil || (state.parkedPrivacy == nil && state.duck.isEmpty)
    }

    /// The owner's own privacy-off on `connection` (#941, Jarvis), under the caller's lock: the park is cleared, and
    /// privacy ends on every other connection of the same device (stale holders of the same phone), decided once their
    /// claims are read, on the notice queue. Another device, or one whose claims are unknown, keeps its privacy.
    func ownerOff(_ connection: UUID, reason: String, in state: inout State) {
        if state.parkedPrivacy != nil { logLater("ambient_park_discarded", detail: "reason=off mode=privacy") }
        state.parkedPrivacy = nil
        let others = state.duck.filter { $0.key != connection }.map { ($0.key, $0.value.token) }
        guard !others.isEmpty else { return }
        let listener = state.listener?.value
        mediaNotices.enqueue { [weak self, weak listener] in
            let here = await listener?.ambientPeerDevice(connection: connection)
            var claims: [PrivacyHolder] = []
            for (other, token) in others {
                // Torn down meanwhile: the claims its teardown parked, if it parked this arming.
                let live = await listener?.ambientPeerDevice(connection: other)
                claims.append(PrivacyHolder(connection: other, token: token,
                                            device: live ?? self?.parkedClaims(of: other, token: token)))
            }
            self?.endSameDevicePrivacy(off: connection, here: here, others: claims, reason: reason)
        }
    }

    /// The claims parked with `connection`'s arming `token`, if its teardown parked it.
    private func parkedClaims(of connection: UUID, token: UUID) -> AmbientPeerDevice? {
        state.withLock { state in
            state.parkedPrivacy.flatMap { $0.connection == connection && $0.token == token ? $0.device : nil }
        }
    }

    /// Ends privacy on each of `others` whose claims match `here`, only while it still holds the arming the off saw:
    /// as an owner's off on it (children, device and reply hold told), or its park cleared if its teardown parked it
    /// meanwhile. Logs how many it cleared and kept, and the connections cleared.
    private func endSameDevicePrivacy(off connection: UUID, here: AmbientPeerDevice?,
                                      others: [PrivacyHolder], reason: String) {
        let cleared = state.withLock { state in
            others.filter { AmbientPeerDevice.matches(here, $0.device) }.compactMap { holder -> UUID? in
                let other = holder.connection
                if state.duck[other]?.token == holder.token {
                    _ = changeDuck(false, connection: other, reason: reason, in: &state)
                    state.privacy[other]?.withdrawAll()
                    return other
                }
                guard let park = state.parkedPrivacy, park.connection == other, park.token == holder.token else {
                    return nil
                }
                state.parkedPrivacy = nil
                return other
            }
        }
        let ids = cleared.map(\.uuidString).joined(separator: ",")
        let kept = others.count - cleared.count
        emit("ambient_privacy_off_scoped", connection: connection,
             detail: "cleared=\(cleared.count) kept=\(kept)" + (ids.isEmpty ? "" : " to=\(ids)"))
    }
}
#endif
