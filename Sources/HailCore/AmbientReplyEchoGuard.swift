public import AVFAudio
import HailProtocol
import Observation
import Synchronization

/// Keeps the phone's own reply out of the ambient stream (#227). While a reply is audible on this device, and for a
/// short tail after it stops, ambient capture yields silence in place of the microphone, so the host's RightyO never
/// transcribes the reply even where echo cancellation leaks. Only samples are zeroed: segment sizes, timing and
/// sequence numbers stay continuous, so the host sees an unbroken stream rather than a gap.
///
/// Masking rises synchronously inside the guarded player, before any call that can make reply audio audible
/// (schedule, resume, replay, unmute), so no reply sample can reach the microphone while the guard is still down.
/// It falls, after the tail, by following `ReplyPlaybackController.isReplyAudioOutputBusy`.
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

    /// Wraps the reply player so masking rises before it can make audio audible.
    @MainActor
    public func guarding(_ player: any ReplyAudioPlaying) -> any ReplyAudioPlaying {
        EchoGuardedReplyPlayer(player: player, echoGuard: self)
    }

    /// Wraps ambient capture so every buffer is silenced while masking, as it leaves the tap and before any
    /// conversion backlog, so masking follows the moment the audio was heard.
    public func masking(_ capture: any AudioCapturing) -> any AudioCapturing {
        EchoMaskedCapture(capture: capture, echoGuard: self)
    }

    /// Voice-processing capture whose processing does not duck the app's reply output, which otherwise left
    /// replies inaudible until listening stopped (#227).
    @MainActor
    public static func voiceProcessingCapture(engine: AVAudioEngine = AVAudioEngine()) throws -> AVAudioEngineCapture {
        let capture = try AmbientAudioStreamer.voiceProcessingCapture(engine: engine)
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = replyDucking
        return capture
    }

    static let replyDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: ObjCBool(false), duckingLevel: .min
    )

    /// Lowers masking, after the tail, when `playback` stops being audible. Only the first call takes effect;
    /// following ends when either side is released.
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

/// Raises the guard before every call that can make reply audio audible. A failed call lowers it again (with the
/// tail), since nothing became audible.
@MainActor
final class EchoGuardedReplyPlayer: ReplyAudioPlaying {
    private let player: any ReplyAudioPlaying
    private let echoGuard: AmbientReplyEchoGuard
    private var isMuted = false

    init(player: any ReplyAudioPlaying, echoGuard: AmbientReplyEchoGuard) {
        self.player = player
        self.echoGuard = echoGuard
    }

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        try audible { try player.schedule(payload, onPlayed: onPlayed) }
    }

    func resume() throws {
        try audible { try player.resume() }
    }

    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        try audible { try player.replaceQueue(with: payloads, onPlayed: onPlayed) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if !muted { echoGuard.setReplyAudible(true) }
        player.setMuted(muted)
    }

    func cancel() { player.cancel() }
    func pause() { player.pause() }

    private func audible(_ operation: () throws -> Void) throws {
        if !isMuted { echoGuard.setReplyAudible(true) }
        do {
            try operation()
        } catch {
            echoGuard.setReplyAudible(false)
            throw error
        }
    }
}

/// Ambient capture whose buffers are silenced while the guard masks.
final class EchoMaskedCapture: AudioCapturing {
    private let capture: any AudioCapturing
    private let echoGuard: AmbientReplyEchoGuard

    init(capture: any AudioCapturing, echoGuard: AmbientReplyEchoGuard) {
        self.capture = capture
        self.echoGuard = echoGuard
    }

    @MainActor
    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        let source = try capture.start()
        let echoGuard = echoGuard
        let (stream, continuation) = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .unbounded)
        let forward = Task.detached {
            for await buffer in source {
                echoGuard.silenceIfMasking(buffer.pcmBuffer)
                continuation.yield(buffer)
            }
            continuation.finish()
        }
        let capture = capture
        // Only a consumer that walks away stops the source; a normal finish means the source already ended, and a
        // late stop could otherwise end a newer run.
        continuation.onTermination = { @Sendable termination in
            guard case .cancelled = termination else { return }
            forward.cancel()
            Task { @MainActor in capture.stop() }
        }
        return stream
    }

    @MainActor
    func stop() { capture.stop() }
}
