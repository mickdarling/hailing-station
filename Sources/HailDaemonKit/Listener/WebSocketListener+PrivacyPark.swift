#if os(macOS)
import Foundation

// Privacy survives drops until the owner clears parked state (#941, #1041).

/// Privacy a dropped connection held (#941): where it was, its arming (`token`), its Hello claims (nil when unknown),
/// when it was parked, and whether the owner had heard it announced there (`heardOn`), so a restored connection's
/// status
/// answers the same. Unlike a parked mode it has no expiry, since privacy has none (Mick, round 2), and it is never
/// consumed by a start: while it is held, every fresh ambient stream on any connection starts private (the claims and
/// its age are logged), until the owner's own privacy-off clears it. In RAM only, so a haild restart restores nothing.
/// `sequence` is its place in parking order (#961): the newest is the one a restore logs, the oldest the one evicted.
struct ParkedPrivacy: Sendable {
    let connection: UUID
    let device: AmbientPeerDevice?
    let parkedAt: Date
    var heard = false
    var token: UUID?
    var sequence = 0
}

/// #941: privacy survives a transport drop. Every fresh ambient stream starts private while any privacy is held
/// elsewhere: parked by a private connection's teardown, or still held by another live connection (haild has no
/// keepalive, so a dropped phone's old connection can outlive its reconnect, MM-E's `live` source). The owner's own
/// privacy-off (voice exit or app switch) clears existing parks and overflow, never another holder's privacy or
/// contribution (#1041). A lingering holder can make a later start private, and its teardown parks privacy again.
/// Hello claims never authorize an off. Logs ids, tokens, counts and booleans only, never words or device names.
extension AmbientRightyoRouter {
    /// The most privacy parks held at once (#961), one per dropped private connection, so a device that drops again
    /// and again cannot grow them without bound. Past it the oldest is evicted and `parkOverflow` set, which keeps
    /// every fresh start private: an eviction only loses that park's details, and fails closed.
    static let maxParkedPrivacy = 16

    /// Parks `connection`'s privacy under the caller's lock (`park`, from `stop(connection:device:)`), before teardown
    /// removes it, as its own entry beside any parked before (#961), never replacing another connection's.
    /// Logs how many are held and whether any was evicted.
    func parkPrivacy(connection: UUID, device: AmbientPeerDevice?, in state: inout State) {
        if state.parks[connection] == nil, state.parks.count >= Self.maxParkedPrivacy,
           let oldest = state.parks.values.min(by: { $0.sequence < $1.sequence }) {
            state.parks[oldest.connection] = nil
            state.parkOverflow = true
            logLater("ambient_park_discarded", connection: oldest.connection, detail: "reason=overflow mode=privacy")
        }
        let sequence = (state.parks.values.map(\.sequence).max() ?? 0) + 1
        state.parks[connection] = ParkedPrivacy(connection: connection, device: device, parkedAt: configuration.now(),
                                                heard: state.privacy[connection]?.heardOn == true,
                                                token: state.duck[connection]?.token, sequence: sequence)
        logLater("ambient_privacy_parked", connection: connection,
                 detail: "parks=\(state.parks.count) overflow=\(state.parkOverflow)")
    }

    /// Carries privacy (#941) onto `connection`'s fresh stream, normal or `resume` alike, under the lock `start` takes
    /// before it makes the child, so the child is launched start-private (S-2b). Fail closed: while any other
    /// connection holds privacy, a park is held or one was evicted (#961), every start is private, whatever its claims
    /// or the park's age (both only logged), onto a connection not torn down and not already private. As a privacy
    /// entry does, under this one lock: the connection's own mode ends (never in both), the agent's replies are held
    /// (S-2c) and its pending ones dropped, and its device is told `duck_mode` on with reason `device` (its own start
    /// after a reconnect changed it; the protocol has no other fitting reason, and a device refuses an unknown one).
    /// No clip, but a status answers as it would where privacy was heard announced.
    func restorePrivacy(to connection: UUID, in state: inout State) {
        guard state.duck[connection] == nil, !state.closed.contains(connection),
              let (source, from) = Self.privacySource(except: connection, in: state) else { return }
        endHeld(connection, reason: "privacy", in: &state)
        let token = UUID()
        state.duck[connection] = AmbientDuckTimer(token: token, timer: nil)
        if Self.privacyHeard(except: connection, in: state) {
            state.privacy[connection, default: .init()].carryHeard()
        }
        let listener = state.listener?.value
        holdReplies(connection, listener: listener)
        // A live holder is never parked, so only a park's age is logged; an overflow has none.
        let age = from.flatMap { state.parks[$0] }.map { " age=\(Self.seconds(configuration.now(), $0.parkedAt))" }
        mediaNotices.enqueue { [weak self, weak listener] in
            let here = await listener?.ambientPeerDevice(connection: connection)
            var there: AmbientPeerDevice?
            if let from { there = await source.device(of: from, listener: listener) }
            let match = AmbientPeerDevice.matches(here, there)
            self?.emit("ambient_privacy_restored", connection: connection,
                       detail: "source=\(source.token) from=\(from?.uuidString ?? "overflow") to=\(connection)"
                           + " device_match=\(match)" + (age ?? ""))
            let sent = await listener?.showDuckMode(true, reason: "device", expires: nil, connection: connection)
            self?.emit("ambient_duck_device", connection: connection,
                       detail: "on=true device=\(sent ?? "no_connection")")
            // A device already gone (#967 second key): the arming is undone, never left on a dead connection.
            self?.disarmIfGone(connection, token: token, sent: sent)
        }
    }

    /// Where a fresh start's privacy comes from (#941): another live connection that holds it (one the owner heard
    /// announced first, then by id, so the log is stable), else the newest park, else an overflow (#961), which has
    /// no connection (nil); nil when there is none.
    static func privacySource(except connection: UUID, in state: State) -> (RestoreSource, UUID?)? {
        let live = state.duck.keys.filter { $0 != connection }
            .sorted { $0.uuidString < $1.uuidString }
        if let holder = live.first(where: { state.privacy[$0]?.heardOn == true }) ?? live.first {
            return (.live, holder)
        }
        if let newest = state.parks.values.max(by: { $0.sequence < $1.sequence }) {
            return (.park(newest.device), newest.connection)
        }
        return state.parkOverflow ? (.park(nil), nil) : nil
    }

    /// Whether the owner heard any of that privacy announced: a live holder's, or a park's. An overflow alone never
    /// counts (#961): what was evicted is unknown, and nothing announced is ever claimed.
    static func privacyHeard(except connection: UUID, in state: State) -> Bool {
        state.parks.values.contains(where: \.heard) || state.duck.keys.contains {
            $0 != connection && state.privacy[$0]?.heardOn == true
        }
    }

    /// Whether a child made for `connection` may hear its stream (#941): only a private one while any other connection
    /// holds privacy, a park is held or one was evicted (#961) (privacy taken elsewhere after its child was made
    /// public, or its restore lost to a teardown).
    static func admitsPrivacy(_ connection: UUID, in state: State) -> Bool {
        state.duck[connection] != nil
            || (state.parks.isEmpty && !state.parkOverflow
                && !state.duck.keys.contains { $0 != connection })
    }

    /// The owner's own off clears parks and overflow already held, under the caller's lock (#941, #1041).
    /// Other private connections keep contributing, including through a later teardown that parks them again.
    func ownerOff(in state: inout State) {
        if !state.parks.isEmpty || state.parkOverflow {
            logLater("ambient_park_discarded",
                     detail: "reason=off mode=privacy count=\(state.parks.count) overflow=\(state.parkOverflow)")
        }
        (state.parks, state.parkOverflow) = ([:], false)
    }
}
#endif
