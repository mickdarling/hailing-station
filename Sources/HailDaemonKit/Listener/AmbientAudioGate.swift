public import Foundation
import HailProtocol

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
/// reply descriptor, at most 8 KB raw per segment, strictly increasing sequence (gaps tolerated). Rate: a
/// 40 KB/s token bucket with a 2 s burst. A violation ends the stream; the connection stays open.
public actor AmbientAudioGate {
    public static let sampleRate = 16_000
    public static let maxSegmentBytes = 8 * 1024
    public static let bytesPerSecond = 40 * 1024
    public static let burstBytes = 2 * bytesPerSecond
    public static let idleTimeout = Duration.seconds(5)

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
    private var lastEnded: UUID?
    private var tokens: Double
    private var refilledAt: ContinuousClock.Instant
    private var sweeper: Task<Void, Never>?

    /// `sweepInterval` drives the 5 s idle end without further traffic; nil leaves expiry to `expireIdle()`.
    public init(
        target: String, sink: any AmbientAudioSink, sweepInterval: Duration? = .seconds(1),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.target = target
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
              audio.reply == nil, audio.bytes.count <= Self.maxSegmentBytes, let stream = audio.streamID else {
            return refuse(.malformed, "ambient segment shape", connection: connection)
        }
        if let current = active, current.id != stream { end(.superseded) }
        if active == nil {
            guard audio.sequence == 0, stream != lastEnded else {
                return refuse(.malformed, "ambient stream must start at sequence 0", connection: connection)
            }
            active = Stream(id: stream, connection: connection, lastSequence: -1, lastActivity: clock())
            sink.ambientAudio(.started(stream: stream, connection: connection))
            startSweeper()
        }
        guard let current = active, audio.sequence > current.lastSequence else {
            return refuse(.malformed, "ambient sequence must increase", connection: connection)
        }
        guard spend(audio.bytes.count) else {
            return refuse(.rateLimited, "ambient rate exceeded", connection: connection)
        }
        active?.lastSequence = audio.sequence
        active?.lastActivity = clock()
        sink.ambientAudio(.segment(stream: stream, sequence: audio.sequence, bytes: audio.bytes))
        if audio.isFinal { end(.final) }
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
        lastEnded = current.id
        sweeper?.cancel()
        sweeper = nil
        sink.ambientAudio(.ended(stream: current.id, reason: reason))
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
