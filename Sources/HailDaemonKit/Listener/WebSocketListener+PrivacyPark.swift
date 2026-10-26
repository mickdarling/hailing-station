#if os(macOS)
import Foundation

// The privacy park, its sources, the owner's scoped off and its provisional verdict are one boundary (#941).
// swiftlint:disable file_length

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

/// The live connection a restored connection took its privacy from (#941), and that connection's arming then.
struct PrivacySource: Sendable {
    let connection: UUID
    let token: UUID
}

/// #941: privacy survives a transport drop. Every fresh ambient stream starts private while any privacy is held
/// elsewhere: parked by a private connection's teardown, or still held by another live connection (haild has no
/// keepalive, so a dropped phone's old connection can outlive its reconnect, MM-E's `live` source). The owner's own
/// privacy-off (voice exit or app switch) clears the park, and ends privacy on the restore's live source only if it is
/// the same class of device and does not answer a ping (Jarvis, #945 round 2). It only ever makes a stream quieter, so
/// unauthenticated Hello claims are never needed to apply it; they only narrow an off, failing closed. Logs ids,
/// tokens, counts and booleans only, never words or device names.
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
        // The lineage an owner's off here may end (Jarvis): the live source and its arming now.
        if case .live = source, let token = state.duck[from]?.token {
            state.privacySources[connection] = PrivacySource(connection: from, token: token)
        }
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

    /// The owner's own privacy-off on `connection` (#941, Jarvis), under the caller's lock. The park is cleared, whatever
    /// device it came from: it has no expiry, and a parked device is not listening. Then, off every lock, the live
    /// connection this one's privacy was restored from (its recorded source) is judged, and its privacy ends only if
    /// all hold: the same class of device (`AmbientPeerDevice.matches`; the app's Hello name is fixed, so in practice
    /// the class), the same arming as at the restore, and no pong to a ping within `privacyProbeTimeout`. The app
    /// sends no idle heartbeat, so silence cannot tell a dead socket from an idle device; a ping can. Any other
    /// private connection keeps its privacy (`not_source`), as does a source that answers (`live`), another or
    /// unknown class (`class`), one re-armed or ended since (`armed`), or one that cannot be probed (`unprobed`).
    func ownerOff(_ connection: UUID, reason: String, in state: inout State) {
        if state.parkedPrivacy != nil { logLater("ambient_park_discarded", detail: "reason=off mode=privacy") }
        state.parkedPrivacy = nil
        let source = state.privacySources.removeValue(forKey: connection)
        let others = state.duck.keys.filter { $0 != connection && $0 != source?.connection }
        guard source != nil || !others.isEmpty else { return }
        let (listener, timeout, hook) = (state.listener?.value, configuration.privacyProbeTimeout,
                                         configuration.offScoping)
        Task { [weak self, weak listener] in
            await hook?(connection)
            var verdict: String?
            if let source {
                verdict = await self?.judge(source, off: connection, listener: listener, timeout: timeout) ?? "unprobed"
            }
            self?.endStaleSource(source, verdict: verdict, off: connection, notSources: others, reason: reason)
        }
    }

    /// Why `source` loses its privacy (`stale`) or keeps it (`class`, `live`, `unprobed`), read off every lock: its
    /// claims, or those its teardown parked if it is gone, against the off's; then a ping.
    private func judge(_ source: PrivacySource, off connection: UUID, listener: WebSocketListener?,
                       timeout: Duration) async -> String {
        guard let listener else { return "unprobed" }
        let here = await listener.ambientPeerDevice(connection: connection)
        let there = await listener.ambientPeerDevice(connection: source.connection)
        guard AmbientPeerDevice.matches(here, there ?? parkedClaims(of: source.connection, token: source.token)) else {
            return "class"
        }
        return await listener.probe(connection: source.connection, within: timeout) { [weak self] in
            self?.latePong(source)
        } ? "live" : "stale"
    }

    /// The claims parked with `connection`'s arming `token`, if its teardown parked it.
    private func parkedClaims(of connection: UUID, token: UUID) -> AmbientPeerDevice? {
        state.withLock { state in
            state.parkedPrivacy.flatMap { $0.connection == connection && $0.token == token ? $0.device : nil }
        }
    }

    /// Ends a stale source's privacy under the lock, only while it still holds the arming the restore recorded: as an
    /// owner's off on it (children, device and reply hold told), or its park cleared if its teardown parked it since;
    /// otherwise it was re-armed or ended meanwhile (`armed`) and is left alone. Logs counts and each connection's
    /// reason.
    private func endStaleSource(_ source: PrivacySource?, verdict: String?, off connection: UUID,
                                notSources: [UUID], reason: String) {
        let outcome = state.withLock { state -> String? in
            guard let source, let verdict else { return nil }
            guard verdict == "stale" else { return verdict }
            // Still streaming (a child of it listening) is a sign of life, whatever the ping said.
            if state.runs.values.contains(where: { $0.connection == source.connection && $0.retiredAt == nil }) {
                return "live"
            }
            if state.duck[source.connection]?.token == source.token {
                _ = changeDuck(false, connection: source.connection, reason: reason, in: &state)
                state.privacy[source.connection]?.withdrawAll()
                // Provisional (Jarvis): any later sign of life puts privacy back.
                state.staleCleared[source.connection] = source.token
                return "stale"
            }
            guard let park = state.parkedPrivacy, park.connection == source.connection,
                  park.token == source.token else { return "armed" }
            state.parkedPrivacy = nil
            return "stale"
        }
        let cleared = outcome == "stale" ? 1 : 0
        let reasons = (source.flatMap { source in outcome.map { ["\(source.connection)=\($0)"] } } ?? [])
            + notSources.map { "\($0)=not_source" }
        emit("ambient_privacy_off_scoped", connection: connection,
             detail: (["cleared=\(cleared)", "kept=\(reasons.count - cleared)"] + reasons).joined(separator: " "))
    }

    /// A sign of life from a connection cleared as stale (#941, Jarvis: the verdict is provisional): a start (normal,
    /// `resume` or a take-over) or a segment of its stream, seen under the lock the gate's events are taken under,
    /// before the event is handled or queued, so its start is made private and no segment reaches a public child.
    func reapplyOnLife(_ event: AmbientAudioEvent, in state: inout State) {
        guard !state.staleCleared.isEmpty else { return }
        switch event {
        case .started(_, let connection, _): reapplyFalseStale(connection, in: &state)
        case .segment(let stream, _, _):
            if let connection = state.latest.first(where: { $0.value == stream })?.key {
                reapplyFalseStale(connection, in: &state)
            }
        case .ended: break
        }
    }

    /// A late pong to the probe that judged `source` stale (#941): it was alive, so its privacy comes back, only while
    /// the mark is still for the arming judged.
    func latePong(_ source: PrivacySource) {
        state.withLock { state in
            guard state.staleCleared[source.connection] == source.token else { return }
            reapplyFalseStale(source.connection, in: &state)
        }
    }

    /// Puts privacy back on a connection wrongly cleared as stale, under the caller's lock, as a restore does: its own
    /// mode ends, it is private (its children are told, so a live one hears nothing until it proves it again, S-8),
    /// the agent's replies are held and its pending ones dropped, and its device is told `duck_mode` on with reason
    /// `device`. No clip. Logged `privacy_reapplied reason=false_stale`.
    func reapplyFalseStale(_ connection: UUID, in state: inout State) {
        guard state.staleCleared.removeValue(forKey: connection) != nil, state.duck[connection] == nil,
              !state.closed.contains(connection) else { return }
        endHeld(connection, reason: "privacy", in: &state)
        state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
        state.runs.values.filter { $0.connection == connection }.forEach { _ = $0.pipeline.reportDuck(true) }
        let listener = state.listener?.value
        holdReplies(connection, listener: listener)
        mediaNotices.enqueue { [weak self, weak listener] in
            self?.emit("privacy_reapplied", connection: connection, detail: "reason=false_stale to=\(connection)")
            let sent = await listener?.showDuckMode(true, reason: "device", expires: nil, connection: connection)
            self?.emit("ambient_duck_device", connection: connection,
                       detail: "on=true device=\(sent ?? "no_connection")")
        }
    }
}
#endif
