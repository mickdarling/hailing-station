#if os(macOS)
import Foundation

// The privacy park, its sources, the owner's scoped off and its provisional verdict are one boundary (#941).
// swiftlint:disable file_length

/// Privacy a dropped connection held (#941): where it was, its arming (`token`), its Hello claims (nil when unknown),
/// when it was parked, and whether the owner had heard it announced there (`heardOn`), so a restored connection's status
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

/// The live connection a restored connection took its privacy from (#941), and that connection's arming then.
struct PrivacySource: Sendable {
    let connection: UUID
    let token: UUID
}

/// #941: privacy survives a transport drop. Every fresh ambient stream starts private while any privacy is held
/// elsewhere: parked by a private connection's teardown, or still held by another live connection (haild has no
/// keepalive, so a dropped phone's old connection can outlive its reconnect, MM-E's `live` source). The owner's own
/// privacy-off (voice exit or app switch) clears every park, and stops the restore's live source counting as a source
/// only if it is the same class of device and does not answer a ping (Jarvis, #945 rounds 2 and 3). It only ever makes a stream quieter, so
/// unauthenticated Hello claims are never needed to apply it; they only narrow an off, failing closed. Logs ids,
/// tokens, counts and booleans only, never words or device names.
extension AmbientRightyoRouter {
    /// The most privacy parks held at once (#961), one per dropped private connection, so a device that drops again
    /// and again cannot grow them without bound. Past it the oldest is evicted and `parkOverflow` set, which keeps
    /// every fresh start private: an eviction only loses that park's lineage, and fails closed.
    static let maxParkedPrivacy = 16

    /// Parks `connection`'s privacy under the caller's lock (`park`, from `stop(connection:device:)`), before teardown
    /// removes it, as its own entry beside any parked before (#961): never replacing another connection's, so a stale
    /// verdict on one drops only its own. Logs how many are held and whether any was evicted.
    func parkPrivacy(connection: UUID, device: AmbientPeerDevice?, in state: inout State) {
        // Excluded as a source by a stale verdict (#941): its privacy contributes nothing more, so it parks nothing.
        guard Self.counts(connection, in: state) else { return }
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
        // The lineage an owner's off here may end (Jarvis): the live source and its arming now.
        if case .live = source, let from, let token = state.duck[from]?.token {
            state.privacySources[connection] = PrivacySource(connection: from, token: token)
        }
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
        let live = state.duck.keys.filter { $0 != connection && counts($0, in: state) }
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
            $0 != connection && counts($0, in: state) && state.privacy[$0]?.heardOn == true
        }
    }

    /// Whether `holder`'s privacy counts as a source for other streams (#941): not while a stale verdict excludes it,
    /// for the arming it still holds. Its own privacy is untouched either way.
    static func counts(_ holder: UUID, in state: State) -> Bool {
        guard let mark = state.staleCleared[holder] else { return true }
        return mark != state.duck[holder]?.token
    }

    /// Whether a child made for `connection` may hear its stream (#941): only a private one while any other connection
    /// holds privacy, a park is held or one was evicted (#961) (privacy taken elsewhere after its child was made
    /// public, or its restore lost to a teardown).
    static func admitsPrivacy(_ connection: UUID, in state: State) -> Bool {
        state.duck[connection] != nil
            || (state.parks.isEmpty && !state.parkOverflow
                && !state.duck.keys.contains { $0 != connection && counts($0, in: state) })
    }

    /// The owner's own privacy-off on `connection` (#941, Jarvis), under the caller's lock. Every park and the overflow
    /// are cleared (#961), whatever device each came from: a park has no expiry, and a parked device is not listening.
    /// Then, off every lock, the live connection this one's privacy was restored from (its recorded source) is judged,
    /// and it stops counting as a source (`endStaleSource`; its own privacy stays) only if all hold: the same class of
    /// device (`AmbientPeerDevice.matches`; the app's Hello name is fixed, so in practice the class), the same arming
    /// as at the restore, and no pong to a ping within `privacyProbeTimeout`. The app sends no idle heartbeat, so
    /// silence cannot tell a dead socket from an idle device; a ping can. Any other private connection keeps counting
    /// (`not_source`), as does a source that answers (`live`), another or unknown class (`class`), one re-armed or
    /// ended since (`armed`), or one that cannot be probed (`unprobed`).
    func ownerOff(_ connection: UUID, reason: String, in state: inout State) {
        if !state.parks.isEmpty || state.parkOverflow {
            logLater("ambient_park_discarded",
                     detail: "reason=off mode=privacy count=\(state.parks.count) overflow=\(state.parkOverflow)")
        }
        (state.parks, state.parkOverflow) = ([:], false)
        let source = state.privacySources.removeValue(forKey: connection)
        // Only holders that still count: one a stale verdict already excluded is not reported again.
        let others = state.duck.keys.filter {
            $0 != connection && $0 != source?.connection && Self.counts($0, in: state)
        }
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

    /// Why `source` stops counting (`stale`) or keeps counting (`class`, `live`, `unprobed`), read off every lock: its
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
        state.withLock { state in state.parks[connection].flatMap { $0.token == token ? $0.device : nil } }
    }

    /// Clears a stale source's contribution under the lock (Jarvis, #945 round 3), only while it still holds the arming
    /// the restore recorded: it stops counting as a source for new streams (`staleCleared`) and its teardown parks
    /// nothing, or its own park is dropped if its teardown parked it since (#961: no other connection's). Its own
    /// privacy is left alone (duck, reply hold, children, device and ledger), so a source wrongly judged stale simply
    /// stays private, and nothing it is sent can leak. Re-armed or ended meanwhile (`armed`): left alone. Logs counts
    /// and each connection's reason. Internal only for its tests.
    func endStaleSource(_ source: PrivacySource?, verdict: String?, off connection: UUID,
                        notSources: [UUID], reason: String) {
        let outcome = state.withLock { state -> String? in
            guard let source, let verdict else { return nil }
            guard verdict == "stale" else { return verdict }
            // Still streaming (a child of it listening) is a sign of life, whatever the ping said.
            if state.runs.values.contains(where: { $0.connection == source.connection && $0.retiredAt == nil }) {
                return "live"
            }
            if state.duck[source.connection]?.token == source.token {
                // Provisional (Jarvis): any later sign of life makes it count again.
                state.staleCleared[source.connection] = source.token
                return "stale"
            }
            guard state.parks[source.connection]?.token == source.token else { return "armed" }
            state.parks[source.connection] = nil
            logLater("ambient_park_discarded", connection: source.connection,
                     detail: "reason=stale mode=privacy parks=\(state.parks.count) overflow=\(state.parkOverflow)")
            return "stale"
        }
        let cleared = outcome == "stale" ? 1 : 0
        let reasons = (source.flatMap { source in outcome.map { ["\(source.connection)=\($0)"] } } ?? [])
            + notSources.map { "\($0)=not_source" }
        emit("ambient_privacy_off_scoped", connection: connection,
             detail: (["cleared=\(cleared)", "kept=\(reasons.count - cleared)"] + reasons).joined(separator: " "))
    }

    /// A sign of life from a source a stale verdict excluded (#941, Jarvis: the verdict is provisional): a start
    /// (normal, `resume` or a take-over) or a segment of its stream, seen under the lock the gate's events are taken
    /// under, before the event is handled or queued. It counts as a source again. Its own start is private anyway: it
    /// was never made public.
    func reapplyOnLife(_ event: AmbientAudioEvent, in state: inout State) {
        guard !state.staleCleared.isEmpty else { return }
        switch event {
        case .started(_, let connection, _): restoreFalseStale(connection, in: &state)
        case .segment(let stream, _, _):
            if let connection = state.latest.first(where: { $0.value == stream })?.key {
                restoreFalseStale(connection, in: &state)
            }
        case .ended: break
        }
    }

    /// A late pong to the probe that judged `source` stale (#941): it was alive, so it counts as a source again, only
    /// while the mark is still for the arming judged.
    func latePong(_ source: PrivacySource) {
        state.withLock { state in
            guard state.staleCleared[source.connection] == source.token else { return }
            restoreFalseStale(source.connection, in: &state)
        }
    }

    /// Lets a source wrongly judged stale count again, under the caller's lock, while its mark is for the arming it
    /// still holds. Nothing else changes: it stayed private. Logged `ambient_privacy_source_restored reason=false_stale`.
    func restoreFalseStale(_ connection: UUID, in state: inout State) {
        guard let mark = state.staleCleared.removeValue(forKey: connection),
              mark == state.duck[connection]?.token else { return }
        logLater("ambient_privacy_source_restored", connection: connection, detail: "reason=false_stale")
    }
}
#endif
