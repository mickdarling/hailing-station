import AVFAudio
import Foundation
import Synchronization

/// Conservative activity measurement over existing capture only. It identifies sound, never a speaker or words.
/// Silence is proved by contiguous measured samples; elapsed time or missing buffers never proves a pause.
final class ProactiveAudioActivity: Sendable {
    typealias Now = @Sendable () -> ContinuousClock.Instant
    static let quietDuration: Duration = .milliseconds(600)
    static let freshness: Duration = .milliseconds(150)
    private static let maximumBufferSeconds = 0.1
    // Copy-time jitter is bounded and never added to the measured sample duration.
    private static let maximumUnmeasuredGap: Duration = .milliseconds(2)
    private static let soundThreshold: Float = 0.003
    private struct State {
        var capture: UUID?
        var epoch: UInt64 = 0
        var last: ContinuousClock.Instant?
        var measuredQuiet: Duration = .zero
        var quietBegan: ContinuousClock.Instant?
        var notifiedQuiet = false
        var changed: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())
    private let now: Now
    init(now: @escaping Now = { .now }) { self.now = now }

    func onChange(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.changed = action } }

    func beginCapture() -> UUID {
        let token = UUID()
        let changed = state.withLock { state in
            state.epoch &+= 1
            state.capture = token
            state.last = nil
            state.measuredQuiet = .zero
            state.quietBegan = nil
            state.notifiedQuiet = false
            return state.changed
        }
        changed?()
        return token
    }

    func endCapture(_ token: UUID) {
        let changed = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.capture == token else { return nil }
            state.epoch &+= 1
            state.capture = nil
            state.last = nil
            state.measuredQuiet = .zero
            state.quietBegan = nil
            state.notifiedQuiet = false
            return state.changed
        }
        changed?()
    }

    /// Producer-side invalidation survives coalesced or delayed main-actor callbacks.
    var epoch: UInt64 { state.withLock { $0.epoch } }
    var isQuiet: Bool { quietEpoch != nil }

    /// Quiet admission and its epoch are read atomically, so an intervening sound cannot mint a fresh permit.
    var quietEpoch: UInt64? {
        let instant = now()
        return state.withLock { state in
            guard state.capture != nil, let last = state.last,
                  instant >= last, instant - last < Self.freshness else { return nil }
            return state.measuredQuiet >= Self.quietDuration ? state.epoch : nil
        }
    }

    /// The next stale-buffer check while proactive speech is active. At most one player watchdog needs it.
    var validUntil: ContinuousClock.Instant? {
        state.withLock { $0.last?.advanced(by: Self.freshness) }
    }

    func observe(_ buffer: AVAudioPCMBuffer, capturedAt instant: ContinuousClock.Instant, capture token: UUID) {
        let received = now()
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let current = received >= instant && received - instant < Self.freshness
        let quiet = current && Self.isMeasuredQuiet(buffer) && seconds > 0 && seconds <= Self.maximumBufferSeconds
        let changed = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.capture == token else { return nil }
            let bufferStart = instant - .seconds(quiet ? seconds : 0)
            let contiguous = state.last.map {
                instant >= $0 && instant - $0 < Self.freshness
                    && bufferStart <= $0.advanced(by: Self.maximumUnmeasuredGap)
            } ?? false
            if !quiet || (state.last != nil && !contiguous) { state.epoch &+= 1 }
            if quiet {
                let duration = Duration.seconds(seconds)
                let began = contiguous ? state.quietBegan ?? instant - duration : instant - duration
                state.quietBegan = began
                state.measuredQuiet = min((contiguous ? state.measuredQuiet : .zero) + duration, instant - began)
            } else {
                state.measuredQuiet = .zero
                state.quietBegan = nil
            }
            state.last = current ? instant : nil
            let isQuiet = state.measuredQuiet >= Self.quietDuration
            guard state.notifiedQuiet != isQuiet else { return nil }
            state.notifiedQuiet = isQuiet
            return state.changed
        }
        changed?()
    }

    private static func isMeasuredQuiet(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0, buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              buffer.format.channelCount > 0, !buffer.format.isInterleaved,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else { return false }
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<Int(buffer.frameLength) {
                let sample = channels[channel][index]
                if !sample.isFinite || abs(sample) >= soundThreshold { return false }
            }
        }
        return true
    }
}
