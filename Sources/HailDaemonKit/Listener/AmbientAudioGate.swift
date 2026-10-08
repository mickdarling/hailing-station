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
public enum AmbientAudioEvent: Sendable, Equatable {
    case started(stream: UUID, connection: UUID)
    case segment(stream: UUID, sequence: Int, bytes: Data)
    case ended(stream: UUID, reason: AmbientStreamEndReason)
}

/// The consumer of admitted ambient audio (#203). Called synchronously from the gate's actor, in order, so
/// an implementation must only enqueue (bounded, drop-with-gap); it must never block or await.
public protocol AmbientAudioSink: Sendable {
    func ambientAudio(_ event: AmbientAudioEvent)
}

/// One opt-in ambient microphone stream per daemon (#203). Shape: pcm16, 16 kHz, mono, a stream id, no
/// reply descriptor, 1 B to 8 KB raw per segment in whole 16-bit samples, strictly increasing sequence (gaps
/// tolerated). Rate: a 40 KB/s token bucket with a 10 s burst, so a network stall that delivers
/// queued audio at once passes (#330). Within a stream an over-rate segment is dropped silently and
/// counted (a dropped final segment still ends the stream), and the stream ends only when it stays over
/// the rate for `overRateGrace`; any other violation ends it at once. The connection stays open. A recently ended stream id is never reopened: the last `endedStreamCapacity` ended ids are
/// kept and the oldest is evicted first (FIFO), so reuse is possible only for an id that ended thousands of
/// streams ago. A start is charged against the bucket before anything is announced or recorded, so a refused
/// start leaves no trace and cannot burn identities.
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

    struct Stream {
        let id: UUID
        let connection: UUID
        var lastSequence: Int
        var lastActivity: ContinuousClock.Instant
    }

    /// The single target an ambient stream may feed; the session's selection must also name it.
    public nonisolated let target: String
    private let sink: any AmbientAudioSink
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let sweepInterval: Duration?
    private var active: Stream?
    private let endedStreamCapacity: Int
    private var ended: Set<UUID> = []
    /// Ended ids in end order, as a ring once full; `evictNext` is the oldest slot.
    private var endedOrder: [UUID] = []
    private var evictNext = 0
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

    /// Nil admits the segment (no reply frame); otherwise the refusal to report on the same connection.
    func admit(
        _ audio: AudioPayload, frameTarget: String?, selectedTarget: String?, connection: UUID
    ) -> (ErrorCode, String)? {
        expireIdle()
        if let owner = active?.connection, owner != connection { return (.notAllowed, "ambient busy") }
        guard frameTarget == target, selectedTarget == target else {
            return refuse(.notAllowed, "ambient target is not selected", connection: connection)
        }
        guard audio.codec == .pcm16, audio.sampleRate == Self.sampleRate, audio.channels == 1,
              audio.reply == nil, Self.wholeSamples(audio.bytes.count), let stream = audio.streamID else {
            return refuse(.malformed, "ambient segment shape", connection: connection)
        }
        if active?.id != stream {
            if let refusal = start(stream, audio: audio, connection: connection) { return refusal }
        } else {
            guard let current = active, audio.sequence > current.lastSequence else {
                return refuse(.malformed, "ambient sequence must increase", connection: connection)
            }
            guard spend(audio.bytes.count) else { return overRate(audio, connection: connection) }
        }
        active?.lastSequence = audio.sequence
        active?.lastActivity = clock()
        sink.ambientAudio(.segment(stream: stream, sequence: audio.sequence, bytes: audio.bytes))
        if audio.isFinal { end(.final) }
        return nil
    }

    /// Opens a stream only after its first segment is validated and paid for. Only then is the owner's current
    /// stream superseded: a refused start (stale or retried id, rate) announces, records and disturbs nothing.
    private func start(_ stream: UUID, audio: AudioPayload, connection: UUID) -> (ErrorCode, String)? {
        guard audio.sequence == 0, !ended.contains(stream) else {
            return (.malformed, "ambient stream must be new and start at sequence 0")
        }
        guard spend(audio.bytes.count) else { return (.rateLimited, "ambient rate exceeded") }
        end(.superseded)
        active = Stream(id: stream, connection: connection, lastSequence: -1, lastActivity: clock())
        sink.ambientAudio(.started(stream: stream, connection: connection))
        startSweeper()
        return nil
    }

    /// Ends `connection`'s stream, if it owns the active one (peer gone, session closed).
    public func end(connection: UUID) {
        guard active?.connection == connection else { return }
        end(.peerEnded)
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
        (overRateSince, lastOverRate) = (nil, nil)
        remember(current.id)
        sweeper?.cancel()
        sweeper = nil
        sink.ambientAudio(.ended(stream: current.id, reason: reason))
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
