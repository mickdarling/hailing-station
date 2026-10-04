import AVFAudio
import Observation
import Synchronization

/// Keeps the phone's own reply out of the ambient stream (#227). While a reply is audible on this device, and for a
/// short tail after it stops, the streamer sends silence in place of the microphone, so the host's RightyO never
/// transcribes the reply even where echo cancellation leaks. Only samples are zeroed: segment sizes, timing and
/// sequence numbers stay continuous, so the host sees an unbroken stream rather than a gap.
public final class AmbientReplyEchoGuard: Sendable {
    /// Covers output latency and room reverberation after the final reply sample.
    public static let defaultTail: Duration = .milliseconds(400)
    public typealias Now = @Sendable () -> ContinuousClock.Instant

    private struct State {
        var audible = false
        var quietAt: ContinuousClock.Instant?
        var following = false
    }

    private let state = Mutex(State())
    private let tail: Duration
    private let now: Now

    public init(tail: Duration = defaultTail, now: @escaping Now = { ContinuousClock.now }) {
        self.tail = tail
        self.now = now
    }

    /// Records whether reply audio is audible now. Becoming inaudible starts the tail; it never shortens one.
    public func setReplyAudible(_ audible: Bool) {
        let instant = now()
        state.withLock { state in
            if audible {
                state.audible = true
                state.quietAt = nil
            } else if state.audible {
                state.audible = false
                state.quietAt = instant.advanced(by: tail)
            }
        }
    }

    /// True while reply audio is audible or its tail has not yet elapsed.
    public var isMasking: Bool {
        let instant = now()
        return state.withLock { state in
            state.audible || state.quietAt.map { instant < $0 } == true
        }
    }

    /// Zeroes the buffer's samples in place while masking, whatever its sample format. Returns whether it did.
    @discardableResult
    func silenceIfMasking(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard isMasking else { return false }
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = channel.mData else { continue }
            data.initializeMemory(as: UInt8.self, repeating: 0, count: Int(channel.mDataByteSize))
        }
        return true
    }

    /// Mirrors `playback.isReplyAudioOutputBusy` from now on. That flag is deliberately conservative across segment
    /// gaps, and false while muted or paused, when nothing is audible. Only the first call takes effect, so a view
    /// may call it on every appearance; following ends when either side is released.
    @MainActor
    public func follow(_ playback: ReplyPlaybackController) {
        guard state.withLock({ state in
            defer { state.following = true }
            return !state.following
        }) else { return }
        track(playback)
    }

    @MainActor
    private func track(_ playback: ReplyPlaybackController) {
        let audible = withObservationTracking {
            playback.isReplyAudioOutputBusy
        } onChange: { [weak self, weak playback] in
            Task { @MainActor in
                guard let self, let playback else { return }
                self.track(playback)
            }
        }
        setReplyAudible(audible)
    }
}
