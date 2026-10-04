public import AVFAudio
import HailProtocol
import Observation
import Synchronization

/// Keeps the phone's own reply out of the ambient stream (#227): while a reply is audible, and for a short tail
/// after, ambient capture yields zeroed samples (timing and sequence numbers unchanged) so RightyO never hears it.
/// Masking rises synchronously in the guarded player before any call that can make audio audible, and falls,
/// after the tail, by following `ReplyPlaybackController.isReplyAudioOutputBusy`.
public final class AmbientReplyEchoGuard: Sendable {
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

    @MainActor
    public func guarding(_ player: any ReplyAudioPlaying) -> any ReplyAudioPlaying {
        EchoGuardedReplyPlayer(player: player, echoGuard: self)
    }

    /// Silences each buffer as it leaves the tap, before any conversion backlog, while masking.
    public func masking(_ capture: any AudioCapturing) -> any AudioCapturing {
        EchoMaskedCapture(capture: capture, echoGuard: self)
    }

    /// Voice-processing capture that does not duck reply output, which otherwise left replies inaudible (#227).
    @MainActor
    public static func voiceProcessingCapture(engine: AVAudioEngine = AVAudioEngine()) throws -> AVAudioEngineCapture {
        let capture = try AmbientAudioStreamer.voiceProcessingCapture(engine: engine)
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = replyDucking
        return capture
    }

    static let replyDucking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
        enableAdvancedDucking: ObjCBool(false), duckingLevel: .min
    )

    /// Lowers masking, after the tail, when `playback` stops being audible. Only the first call takes effect.
    @MainActor
    public func follow(_ playback: ReplyPlaybackController) {
        guard state.withLock({ state in
            defer { state.following = true }
            return !state.following
        }) else { return }
        (playback.player as? EchoGuardedReplyPlayer)?.playback = playback
        track(playback)
    }

    /// Observes every input of the busy flag, past its short-circuit, so masking never outlasts an idle tail.
    @MainActor
    private func track(_ playback: ReplyPlaybackController) {
        let audible = withObservationTracking {
            _ = (playback.activeKey, playback.isPaused, playback.isMuted, playback.isCaptureSuppressed)
            return playback.isReplyAudioOutputBusy
        } onChange: { [weak self, weak playback] in
            Task { @MainActor in
                guard let self, let playback else { return }
                self.track(playback)
            }
        }
        setReplyAudible(audible)
    }
}

/// Raises the guard before every call that can make reply audio audible; a failed call lowers it (with the tail).
/// Each raise is re-checked one main-actor turn later against the followed controller, as a backstop.
@MainActor
final class EchoGuardedReplyPlayer: ReplyAudioPlaying {
    private let player: any ReplyAudioPlaying
    private let echoGuard: AmbientReplyEchoGuard
    weak var playback: ReplyPlaybackController?
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

    /// `isMuted` is already flipped here, so busy says whether unmuting is audible; idle or paused leaves it down.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        if !muted, playback?.isReplyAudioOutputBusy ?? true { raise() }
        player.setMuted(muted)
    }

    func cancel() { player.cancel() }
    func pause() { player.pause() }

    private func raise() {
        echoGuard.setReplyAudible(true)
        Task { @MainActor [weak self] in
            guard let self, let playback else { return }
            echoGuard.setReplyAudible(playback.isReplyAudioOutputBusy)
        }
    }

    private func audible(_ operation: () throws -> Void) throws {
        if !isMuted { raise() }
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
        // Only a consumer walking away stops the source; after a normal finish a late stop could end a newer run.
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
