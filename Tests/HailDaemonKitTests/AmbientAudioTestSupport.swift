import Foundation
import HailProtocol
import Synchronization
@testable import HailDaemonKit

final class RecordingAmbientSink: AmbientAudioSink {
    private let recorded = Mutex<[AmbientAudioEvent]>([])
    var events: [AmbientAudioEvent] { recorded.withLock { $0 } }
    var segments: [Int] {
        events.compactMap { if case .segment(_, let sequence, _) = $0 { sequence } else { nil } }
    }
    var endings: [AmbientStreamEndReason] {
        events.compactMap { if case .ended(_, let reason) = $0 { reason } else { nil } }
    }
    func ambientAudio(_ event: AmbientAudioEvent) { recorded.withLock { $0.append(event) } }
}

final class AmbientTestClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = Mutex<Duration>(.zero)
    func advance(_ by: Duration) { offset.withLock { $0 += by } }
    var now: ContinuousClock.Instant { base + offset.withLock { $0 } }
}

func ambientGate(
    target: String = "tmux:a", sink: RecordingAmbientSink, clock: AmbientTestClock,
    endedStreamCapacity: Int = AmbientAudioGate.defaultEndedStreamCapacity
) -> AmbientAudioGate {
    AmbientAudioGate(
        target: target, sink: sink, sweepInterval: nil, endedStreamCapacity: endedStreamCapacity,
        clock: { clock.now }
    )
}

func ambientSegment(
    stream: UUID?, sequence: Int, bytes: Int = 3_200, isFinal: Bool = false,
    codec: AudioCodec = .pcm16, sampleRate: Int = 16_000, channels: Int = 1
) -> AudioPayload {
    AudioPayload(
        codec: codec, sampleRate: sampleRate, channels: channels, sequence: sequence,
        streamID: stream, isFinal: isFinal, bytes: Data(repeating: 0, count: bytes)
    )
}

extension AmbientAudioGate {
    func admit(_ audio: AudioPayload, connection: UUID, target: String = "tmux:a") -> ErrorCode? {
        admit(audio, frameTarget: target, selectedTarget: target, connection: connection)?.0
    }
}
