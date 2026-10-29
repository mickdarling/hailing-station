public import Foundation
import HailProtocol

// Admission, rate and stream identity form one review boundary on the security-critical listener path.
// swiftlint:disable file_length

/// Why an ambient stream stopped. The sink treats every case alike (close the consumer's input); the reason
/// is for counts and tests, never for content.
public enum AmbientStreamEndReason: Sendable, Equatable {
    case final, idle, superseded, peerEnded, malformed, rateLimited, notAllowed
}

/// What the gate hands on. `segment` carries raw pcm16 bytes; nothing in this module logs or describes them.
/// `selection` is the selection generation the connection's session had when the stream opened (#636), nil from a
/// caller that tracks none.
public enum AmbientAudioEvent: Sendable, Equatable {
    case started(stream: UUID, connection: UUID, selection: UUID? = nil)
    case segment(stream: UUID, sequence: Int, bytes: Data)
    case ended(stream: UUID, reason: AmbientStreamEndReason)
}

/// The gate's answer to one segment (#366). `tookOver` admits a segment whose new stream took ambient listening
/// over from another connection; `from` is that connection's device class, if it gave one.
enum AmbientAdmission: Sendable, Equatable {
    case admitted
    case tookOver(from: String?)
    case refused(ErrorCode, String)
}

/// The connection's selection with one segment, as its session sees it (#636): the selected target and its selection
/// generation. A stream keeps the generation it opened on, so what it heard is never delivered once the owner has
/// selected another destination, even after selecting this one again.
struct AmbientSelection: Sendable, Equatable {
    var target: String?
    var generation: UUID?
}

/// The consumer of admitted ambient audio (#203). Called synchronously from the gate's actor, in order, so
/// an implementation must only enqueue (bounded, drop-with-gap); it must never block or await.
public protocol AmbientAudioSink: Sendable {
    func ambientAudio(_ event: AmbientAudioEvent)
    /// A connection's ambient input route kind changed (rightyo#164): one of `AmbientInput.routes`, never a port or
    /// device name, so speaker-ID results can be attributed to an input chain. Same rules as `ambientAudio`.
    func ambientInputRoute(_ route: String, connection: UUID)
    /// A device's privacy switch (#735 S-6, `set_privacy`) for its own connection, which holds the active ambient
    /// stream. Same rules as `ambientAudio`. A sink without privacy mode ignores it.
    func ambientPrivacy(_ on: Bool, connection: UUID)
    /// A device's privacy re-asserted (#904, `set_privacy` on) on its own connection before that connection opened any
    /// stream, so its first one starts private. Same rules as `ambientAudio`. A sink without it ignores it, which fails
    /// closed: the device is never told privacy is on.
    func ambientPrivacyPreArm(connection: UUID)
    /// A pre-arm the gate refused (#904), with a fixed reason token: `ended`, a connection this gate already ended (a
    /// `set_privacy` on still in flight at its teardown). Same rules as `ambientAudio`; for the log only.
    func ambientPrivacyPreArmRefused(connection: UUID, reason: String)
}

extension AmbientAudioSink {
    public func ambientInputRoute(_ route: String, connection: UUID) {}
    public func ambientPrivacy(_ on: Bool, connection: UUID) {}
    public func ambientPrivacyPreArm(connection: UUID) {}
    public func ambientPrivacyPreArmRefused(connection: UUID, reason: String) {}
}

/// One opt-in ambient microphone stream per daemon (#203). Shape: pcm16, 16 kHz, mono, a stream id, no
/// reply descriptor, 1 B to 8 KB raw per segment in whole 16-bit samples, strictly increasing sequence (gaps
/// tolerated). Rate: a 40 KB/s token bucket with a 10 s burst, so a network stall that delivers
/// queued audio at once passes (#330). Within a stream an over-rate segment is dropped silently and
/// counted (a dropped final segment still ends the stream), and the stream ends only when it stays over
/// the rate for `overRateGrace`; any other violation ends it at once. The connection stays open. A recently ended
/// stream id is never reopened: the last `endedStreamCapacity` ended ids are
/// kept and the oldest is evicted first (FIFO), so reuse is possible only for an id that ended thousands of
/// streams ago. A start is charged against the bucket before anything is announced or recorded, so a refused
/// start leaves no trace and cannot burn identities.
///
/// Take-over (#366): the most recent device to start a stream holds it. A valid first segment of a new stream from
/// another connection ends the current stream as `superseded` and opens the new one; the previous owner's further
/// segments of its ended stream are refused with `AmbientTakeOver.movedMessage`, a final refusal on the phone.
/// Only a connection this daemon negotiated, whose authorizer admitted the audio frame and whose selection names
/// this gate's target, can take over, and only with a start that passes every check here; a refused start disturbs
/// nothing. A `resume` start (#373), a device's automatic restart, never takes over: it opens a stream only when no
/// other connection holds one, and is otherwise refused with the moved message. The gate belongs to one daemon
/// and its one target, so nothing is taken over across hosts.
public actor AmbientAudioGate {
    public static let sampleRate = 16_000
    public static let maxSegmentBytes = 8 * 1024
    public static let bytesPerSecond = 40 * 1024
    public static let burstBytes = 10 * bytesPerSecond
    /// How long a stream may keep dropping over-rate segments before it ends (#330). Real audio averages 32 KB/s,
    /// under the rate, so a stall's catch-up drops in one instant and stops; only a sender that keeps exceeding
    /// the rate keeps dropping. An episode ends after `overRateQuiet` without a drop.
    public static let overRateGrace = Duration.seconds(5)
    public static let overRateQuiet = Duration.seconds(1)
    /// Long enough for a phone listening in the background, where iOS can pause sends for several seconds without
    /// an interruption (5 s ended a live stream on device, #282). A real disconnect still ends it at once.
    public static let idleTimeout = Duration.seconds(30)
    /// Default bound on remembered ended ids (16 B each, about 64 KB); the oldest is evicted at the bound.
    public static let defaultEndedStreamCapacity = 4_096
    /// Taken-over streams remembered so their owner is told where listening went (#366); the oldest is evicted.
    public static let movedStreamCapacity = 64

    /// A stream ended by a take-over (#366): the connection that owned it and the new owner's device class.
    struct Move {
        let stream: UUID
        let connection: UUID
        let to: String?
    }

    struct Stream {
        let id: UUID
        let connection: UUID
        /// The owner's device class from its hello (#366), or nil; used only to name it to the next owner.
        let device: String?
        var lastSequence: Int
        var lastActivity: ContinuousClock.Instant
        /// The session's selection generation when the stream opened (#636), nil from a caller that tracks none.
        var selection: UUID?
        var policyGeneration: TargetPolicyGeneration?
    }

    /// The single target an ambient stream may feed; the session's selection must also name it.
    public nonisolated let target: String
    /// Ends a stream opened before the owner selected away and back (#636).
    static let reselectedMessage = "ambient stopped: the destination was selected again"
    private let sink: any AmbientAudioSink
    /// Gate state commits under the generation lock; callbacks run after it releases (#1028).
    private var admissionEvents: [AmbientAudioEvent]?
    /// Each live connection's last reported input route kind (rightyo#164), dropped when it disconnects.
    private var inputRoutes: [UUID: String] = [:]
    /// Live connections that opened a stream here (#904), dropped when they disconnect: only one not in it may pre-arm
    /// privacy. A refused start never adds one.
    private var streamed: Set<UUID> = []
    /// Connections this gate ended (#904), the last `endedStreamCapacity` of them, kept and evicted (oldest first) as
    /// ended streams are: a pre-arm still in flight when its connection was torn down is refused, so no privacy is
    /// armed for a connection that is gone. `evictConnectionNext` is the oldest slot once the ring is full.
    private var endedConnections: Set<UUID> = []
    private var endedConnectionOrder: [UUID] = []
    private var evictConnectionNext = 0
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let sweepInterval: Duration?
    private var active: Stream?
    private let endedStreamCapacity: Int
    private var ended: Set<UUID> = []
    /// Ended ids in end order, as a ring once full; `evictNext` is the oldest slot.
    private var endedOrder: [UUID] = []
    private var evictNext = 0
    /// Streams ended by a take-over (#366), oldest first: the connection that owned each and the new device class.
    private var moved: [Move] = []
    private var tokens: Double
    private var refilledAt: ContinuousClock.Instant
    private var sweeper: Task<Void, Never>?
    /// The active stream's current over-rate episode: its first and latest dropped segment.
    private var overRateSince: ContinuousClock.Instant?, lastOverRate: ContinuousClock.Instant?
    /// Segments dropped as over the rate (#330), across streams. A count only.
    public private(set) var overRateDropped = 0

    /// `sweepInterval` drives the idle end without further traffic; nil leaves expiry to `expireIdle()`.
    public init(
        target: String, sink: any AmbientAudioSink, sweepInterval: Duration? = .seconds(1),
        endedStreamCapacity: Int = defaultEndedStreamCapacity,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.target = target
        self.endedStreamCapacity = max(1, endedStreamCapacity)
        self.sink = sink
        self.clock = clock
        self.sweepInterval = sweepInterval
        tokens = Double(Self.burstBytes)
        refilledAt = clock()
    }

    /// Ends `connection`'s stream, if it owns the active one (peer gone, session closed), and forgets its moves.
    public func end(connection: UUID) {
        moved.removeAll { $0.connection == connection }
        inputRoutes[connection] = nil
        streamed.remove(connection)
        rememberEnded(connection: connection)
        guard active?.connection == connection else { return }
        end(.peerEnded)
    }

    /// Notes `connection`'s input route kind (rightyo#164), already from the closed vocabulary. Within a stream only a
    /// change is handed on, so a device repeating its route cannot flood the log; one entry per live connection, and
    /// none once its stream ends.
    public func noteInputRoute(_ route: String, connection: UUID) {
        guard AmbientInput.route(route) != nil, inputRoutes[connection] != route else { return }
        inputRoutes[connection] = route
        sink.ambientInputRoute(route, connection: connection)
    }

    /// Hands on a device's privacy switch (#735 S-6) for `connection`, the session's own connection id, so a device
    /// switches only its own privacy. On while that connection holds the active ambient stream. Off also after
    /// its stream ended (Jarvis: the host stopped listening because no child could keep privacy, and the switch is
    /// then the way out); the connection's privacy lives until the connection ends. An on from a connection that has
    /// not opened a stream here yet is its pre-arm (#904: a device re-asserting privacy on a new connection before it
    /// resumes), whoever else is listening; an on from one whose stream ended stays refused (Jarvis), and so does one
    /// from a connection this gate already ended (its teardown ran while the on was in flight), reported as `ended`.
    /// Otherwise nothing is handed on. Whether privacy already is as asked is the sink's to check.
    public func setPrivacy(_ on: Bool, connection: UUID) {
        if !on || active?.connection == connection { return sink.ambientPrivacy(on, connection: connection) }
        guard !endedConnections.contains(connection) else {
            return sink.ambientPrivacyPreArmRefused(connection: connection, reason: "ended")
        }
        guard !streamed.contains(connection) else { return }
        sink.ambientPrivacyPreArm(connection: connection)
    }

    /// Ends the active stream once it has been silent for `idleTimeout`.
    public func expireIdle() {
        guard let current = active, clock() - current.lastActivity >= Self.idleTimeout else { return }
        end(.idle)
    }

    var activeStream: UUID? { active?.id }

    /// Drops an over-rate segment of the active stream without a reply: the phone ends ambient on an `ambient`
    /// error. Only a stream whose drops go on for `overRateGrace`, with no `overRateQuiet` gap, is refused and ended.
    private func overRate(_ audio: AudioPayload, connection: UUID) -> (ErrorCode, String)? {
        let now = clock()
        if let last = lastOverRate, now - last < Self.overRateQuiet {} else { overRateSince = now }
        lastOverRate = now
        guard let since = overRateSince, now - since < Self.overRateGrace else {
            return refuse(.rateLimited, "ambient rate exceeded", connection: connection)
        }
        overRateDropped += 1
        active?.lastSequence = audio.sequence
        active?.lastActivity = now
        // The phone sends its final segment last, so it lands at the end of a catch-up burst: it still ends.
        if audio.isFinal { end(.final) }
        return nil
    }

    private func refuse(_ code: ErrorCode, _ message: String, connection: UUID) -> (ErrorCode, String) {
        if active?.connection == connection {
            switch code {
            case .rateLimited: end(.rateLimited)
            case .malformed: end(.malformed)
            default: end(.notAllowed)
            }
        }
        return (code, message)
    }

    private func end(_ reason: AmbientStreamEndReason) {
        guard let current = active else { return }
        active = nil
        // A stream boundary (rightyo#164): the next stream's route is noted and reaches its child again.
        inputRoutes[current.connection] = nil
        (overRateSince, lastOverRate) = (nil, nil)
        remember(current.id)
        sweeper?.cancel()
        sweeper = nil
        emit(.ended(stream: current.id, reason: reason))
    }

    private func remember(_ id: UUID) {
        guard ended.insert(id).inserted else { return }
        guard endedOrder.count == endedStreamCapacity else { return endedOrder.append(id) }
        ended.remove(endedOrder[evictNext])
        endedOrder[evictNext] = id
        evictNext = (evictNext + 1) % endedStreamCapacity
    }

    /// Non-empty, at most `maxSegmentBytes`, and whole 16-bit samples: an empty segment would cost no tokens.
    private static func wholeSamples(_ count: Int) -> Bool {
        count > 0 && count <= maxSegmentBytes && count.isMultiple(of: MemoryLayout<Int16>.size)
    }

    /// The bucket is daemon-wide, so a new stream cannot reset an exhausted budget.
    private func spend(_ count: Int) -> Bool {
        let now = clock()
        let elapsed = now - refilledAt
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(Double(Self.burstBytes), tokens + seconds * Double(Self.bytesPerSecond))
        refilledAt = now
        guard Double(count) <= tokens else { return false }
        tokens -= Double(count)
        return true
    }

    private func startSweeper() {
        guard let interval = sweepInterval, sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.expireIdle()
            }
        }
    }
}

/// Admission (#203) with take-over (#366).
extension AmbientAudioGate {
    /// Nil admits the segment (no reply frame); otherwise the refusal to report on the same connection.
    func admit(
        _ audio: AudioPayload, frameTarget: String?, selectedTarget: String?, connection: UUID, device: String? = nil
    ) -> (ErrorCode, String)? {
        guard case .refused(let code, let message) = admission(
            audio, frameTarget: frameTarget, selectedTarget: selectedTarget, connection: connection, device: device
        ) else { return nil }
        return (code, message)
    }

    /// One segment from `connection`, whose device said it is `device` (#366). A refusal is reported on the same
    /// connection; `tookOver` also tells it that its new stream took listening over from another connection.
    func admission(
        _ audio: AudioPayload, frameTarget: String?, selectedTarget: String?, connection: UUID, device: String?
    ) -> AmbientAdmission {
        admission(audio, frameTarget: frameTarget, selection: AmbientSelection(target: selectedTarget),
                  connection: connection, device: device)
    }

    /// The same, with the session's selection generation, which a stream this segment opens keeps (#636).
    func admission(
        _ audio: AudioPayload, frameTarget: String?, selection: AmbientSelection, connection: UUID, device: String?,
        policyGeneration: TargetPolicyGeneration? = nil
    ) -> AmbientAdmission {
        admissionEvents = []
        // Continue under the stream's original grant, never a replacement obtained after a write (#1028).
        let retained = active.flatMap { $0.id == audio.streamID && $0.connection == connection ? $0 : nil }
        let expected = retained?.policyGeneration ?? policyGeneration
        // Observe after the admission hop, outside the generation lock; no suspension precedes the compare.
        expected?.observePolicy()
        let result: AmbientAdmission
        // Compare and commit only gate state/events under the lock; no sink, child validation, spawn or await.
        if let expected, expected.target == target, let admitted = expected.performIfCurrent({
            let result = admitCurrent(audio, frameTarget: frameTarget, selection: selection,
                                      connection: connection, device: device)
            if active?.id == audio.streamID, active?.connection == connection { active?.policyGeneration = expected }
            return result
        }) {
            result = admitted
        } else if expected == nil {
            result = admitCurrent(audio, frameTarget: frameTarget, selection: selection,
                                  connection: connection, device: device)
        } else {
            let changed = expected?.target == target && expected?.wasGranted == true
            let message = changed ? "ambient target_policy_changed"
                : "ambient target is not allowed — run haild targets allow on the Mac"
            let refusal = refuse(.notAllowed, message, connection: connection)
            result = .refused(refusal.0, refusal.1)
        }
        return publishAdmission(result, expected: expected, stream: audio.streamID, connection: connection)
    }

    private func emit(_ event: AmbientAudioEvent) {
        if admissionEvents != nil { admissionEvents?.append(event) } else { sink.ambientAudio(event) }
    }

    private func publishAdmission(
        _ result: AmbientAdmission, expected: TargetPolicyGeneration?, stream: UUID?, connection: UUID
    ) -> AmbientAdmission {
        let events = admissionEvents ?? []
        admissionEvents = nil
        defer { if active != nil { startSweeper() } }
        // In particular, .started may validate/spawn a child synchronously. The generation lock is released.
        for event in events {
            switch event {
            case .started: break
            case .segment(let id, _, _), .ended(let id, _):
                if let expected, id == stream {
                    // At most one staged segment (<= 8 KB) may publish as a write returns, linearized before the write.
                    let current: Bool = expected.performIfCurrent({ true }) == true
                    if !current {
                        if active?.id == id, active?.connection == connection {
                            end(.notAllowed)
                        } else {
                            // A final packet already cleared active while staging: replace its unpublished end.
                            sink.ambientAudio(.ended(stream: id, reason: .notAllowed))
                        }
                        return .refused(.notAllowed, "ambient target_policy_changed")
                    }
                }
            }
            sink.ambientAudio(event)
        }
        return result
    }

    private func admitCurrent(
        _ audio: AudioPayload, frameTarget: String?, selection: AmbientSelection, connection: UUID, device: String?
    ) -> AmbientAdmission {
        expireIdle()
        if let stream = audio.streamID,
           let move = moved.last(where: { $0.stream == stream && $0.connection == connection }) {
            return .refused(.notAllowed, AmbientTakeOver.movedMessage(to: move.to))
        }
        let previous = active.flatMap { $0.connection == connection ? nil : $0 }
        guard let refusal = check(audio, frameTarget: frameTarget, selection: selection,
                                  connection: connection, device: device) else {
            return previous.map { .tookOver(from: $0.device) } ?? .admitted
        }
        return .refused(refusal.0, refusal.1)
    }

    private func check(
        _ audio: AudioPayload, frameTarget: String?, selection: AmbientSelection, connection: UUID, device: String?
    ) -> (ErrorCode, String)? {
        guard frameTarget == target, selection.target == target else {
            return refuse(.notAllowed, "ambient target is not selected", connection: connection)
        }
        guard audio.codec == .pcm16, audio.sampleRate == Self.sampleRate, audio.channels == 1,
              audio.reply == nil, Self.wholeSamples(audio.bytes.count), let stream = audio.streamID else {
            return refuse(.malformed, "ambient segment shape", connection: connection)
        }
        if active?.id != stream {
            if let refusal = start(stream, audio: audio, connection: connection, device: device,
                                   selection: selection.generation) { return refusal }
        } else {
            // Another connection's stream id is never continued, and refusing it leaves that stream untouched.
            guard active?.connection == connection else { return (.notAllowed, "ambient stream is not this device's") }
            guard let current = active, audio.sequence > current.lastSequence else {
                return refuse(.malformed, "ambient sequence must increase", connection: connection)
            }
            // The owner selected away and back since it opened (#636): nothing it hears now could be delivered, so it
            // ends here, ahead of the rate budget, rather than letting RightyO acknowledge a turn the host will refuse.
            // The device reads an "ambient stopped:" refusal as transient and, after its recovery backoff, opens a
            // fresh stream on the new selection. Only a stream opened and continued with no generation skips this.
            guard current.selection == selection.generation else {
                return refuse(.notAllowed, Self.reselectedMessage, connection: connection)
            }
            guard spend(audio.bytes.count) else { return overRate(audio, connection: connection) }
        }
        active?.lastSequence = audio.sequence
        active?.lastActivity = clock()
        emit(.segment(stream: stream, sequence: audio.sequence, bytes: audio.bytes))
        if audio.isFinal { end(.final) }
        return nil
    }

    /// Opens a stream only after its first segment is validated and paid for. Only then is the current stream,
    /// this connection's or another's (#366), superseded: a refused start (stale or retried id, rate) announces,
    /// records and disturbs nothing.
    private func start(
        _ stream: UUID, audio: AudioPayload, connection: UUID, device: String?, selection: UUID?
    ) -> (ErrorCode, String)? {
        guard audio.sequence == 0, !ended.contains(stream) else {
            return (.malformed, "ambient stream must be new and start at sequence 0")
        }
        // A device's own automatic restart (#373) only resumes when nobody else is listening: it never takes
        // listening back from the device someone moved to. It is told where listening went, as a moved device is.
        if audio.isResume, let current = active, current.connection != connection {
            return (.notAllowed, AmbientTakeOver.movedMessage(to: current.device))
        }
        guard spend(audio.bytes.count) else { return (.rateLimited, "ambient rate exceeded") }
        let device = AmbientTakeOver.deviceKind(device)
        if let previous = active, previous.connection != connection {
            moved.append(Move(stream: previous.id, connection: previous.connection, to: device))
            moved.removeFirst(max(0, moved.count - Self.movedStreamCapacity))
        }
        end(.superseded)
        active = Stream(id: stream, connection: connection, device: device, lastSequence: -1, lastActivity: clock(),
                        selection: selection)
        streamed.insert(connection)
        emit(.started(stream: stream, connection: connection, selection: selection))
        return nil
    }
}

/// Ended connections (#904), kept as ended streams are.
extension AmbientAudioGate {
    /// The ring `remember` keeps for ended streams, for ended connections, with the same bound.
    private func rememberEnded(connection: UUID) {
        guard endedConnections.insert(connection).inserted else { return }
        guard endedConnectionOrder.count == endedStreamCapacity else { return endedConnectionOrder.append(connection) }
        endedConnections.remove(endedConnectionOrder[evictConnectionNext])
        endedConnectionOrder[evictConnectionNext] = connection
        evictConnectionNext = (evictConnectionNext + 1) % endedStreamCapacity
    }
}
