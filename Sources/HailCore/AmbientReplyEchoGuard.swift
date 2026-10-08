// Reply routing through the capture engine (#269) stays beside the guard/player it changes, within the four-file budget.
// swiftlint:disable file_length
public import AVFAudio
import HailProtocol
import Observation
import Synchronization

/// Keeps the phone's own reply out of the ambient stream (#227): while a reply is audible, and for a short tail
/// after, ambient capture yields zeroed samples (timing and sequence numbers unchanged) so RightyO never hears it.
/// With `echoCancelledCapture()` (#269) replies play through the capture's voice-processing engine instead, so the
/// mic stays open while a reply plays and Mick can talk over it; masking then applies only if `masksDuringReplies`
/// is set (an A/B switch), the reply could not be routed through the capture engine, or that engine is plain
/// capture without voice processing (#343, #356).
/// Masking rises synchronously in the guarded player before any call that can make audio audible, and falls,
/// after the tail, by following `ReplyPlaybackController.isReplyAudioOutputBusy`.
public final class AmbientReplyEchoGuard: Sendable {
    public static let defaultTail: Duration = .milliseconds(400)
    public typealias Now = @Sendable () -> ContinuousClock.Instant

    private struct State {
        var audible = false
        var quietAt: ContinuousClock.Instant?
        var following = false
        var routedThroughCapture = false
        var masksDuringReplies = false
    }

    private let state = Mutex(State())
    private let route = ReplyRoute()
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
            guard state.masksDuringReplies || !state.routedThroughCapture else { return false }
            return state.audible || state.quietAt.map { instant < $0 } == true
        }
    }

    /// A/B switch (#269): zero the mic during replies even when they are echo-cancelled.
    public var masksDuringReplies: Bool {
        get { state.withLock { $0.masksDuringReplies } }
        set { state.withLock { $0.masksDuringReplies = newValue } }
    }

    /// Whether replies currently play through the capture engine's echo canceller.
    public var isEchoCancelling: Bool { state.withLock { $0.routedThroughCapture } }

    func setRoutedThroughCapture(_ routed: Bool) {
        state.withLock { $0.routedThroughCapture = routed }
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
        route.player = player as? PCM16AudioPlayer
        return EchoGuardedReplyPlayer(player: player, echoGuard: self)
    }

    /// Silences each buffer as it leaves the tap, before any conversion backlog, while masking.
    public func masking(_ capture: any AudioCapturing) -> any AudioCapturing {
        EchoMaskedCapture(capture: capture, echoGuard: self)
    }

    /// Voice-processing capture whose engine also plays replies while it runs, so Apple's echo canceller removes
    /// them from the mic (#269). Masking stays as the fallback when the guarded player is not a PCM16AudioPlayer.
    /// Call after `ManagedAudioSession` has activated a play-and-record session.
    @MainActor
    public func echoCancelledCapture() throws -> any AudioCapturing {
        let engine = AVAudioEngine()
        _ = engine.mainMixerNode // Wire the output path before the engine first starts.
        let capture = try Self.voiceProcessingCapture(engine: engine)
        return EchoMaskedCapture(capture: capture, echoGuard: self,
                                 routing: CaptureReplyRouting(engine: engine, route: route, echoGuard: self))
    }

    /// Ambient capture for `mode` (#343). Voice processing echo-cancels replies through the capture engine. Plain
    /// capture, for headphone routes, also plays replies through its own engine (#356): replies on a second engine
    /// beside the plain capture engine stuttered on A2DP. Nothing cancels echo there, so the guard keeps silencing
    /// the mic while a reply is audible. `plainCapture` makes the engine capture for plain mode.
    @MainActor
    public func ambientCapture(
        mode: AmbientCaptureMode,
        plainCapture: @MainActor (AVAudioEngine) -> any AudioCapturing = { AVAudioEngineCapture(engine: $0) }
    ) throws -> any AudioCapturing {
        switch mode {
        case .voiceProcessing: return try echoCancelledCapture()
        case .plain:
            let engine = AVAudioEngine()
            _ = engine.mainMixerNode // Wire the output path before the engine first starts.
            let routing = CaptureReplyRouting(engine: engine, route: route, echoGuard: self, cancelsEcho: false)
            return EchoMaskedCapture(capture: plainCapture(engine), echoGuard: self, routing: routing)
        }
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

/// The reply player that echo-cancelled capture moves onto its engine. Only the main actor touches it.
final class ReplyRoute: @unchecked Sendable {
    @MainActor weak var player: PCM16AudioPlayer?
}

/// Moves replies onto a running capture engine and back again, keeping the guard's routing flag truthful. The
/// flag means "echo-cancelled", so a plain engine (`cancelsEcho: false`) never lowers masking.
@MainActor
final class CaptureReplyRouting {
    private let engine: AVAudioEngine
    private let route: ReplyRoute
    private let echoGuard: AmbientReplyEchoGuard
    private let cancelsEcho: Bool

    init(engine: AVAudioEngine, route: ReplyRoute, echoGuard: AmbientReplyEchoGuard, cancelsEcho: Bool = true) {
        self.engine = engine
        self.route = route
        self.echoGuard = echoGuard
        self.cancelsEcho = cancelsEcho
    }

    func attach() {
        guard let player = route.player else { return }
        player.route(through: engine)
        let routed = player.isRoutedThroughCapture
        echoGuard.setRoutedThroughCapture(Self.echoCancelled(cancelsEcho: cancelsEcho, routed: routed))
    }

    /// Replies count as echo-cancelled only on a voice-processing engine that is actually playing them.
    nonisolated static func echoCancelled(cancelsEcho: Bool, routed: Bool) -> Bool { cancelsEcho && routed }

    /// A no-op once a newer run has attached: a quick off-on must not pull replies off the new engine.
    func detach() {
        if let player = route.player, player.isOnAnotherCapture(than: engine) { return }
        echoGuard.setRoutedThroughCapture(false)
        route.player?.route(through: nil)
    }
}

/// Ambient capture whose buffers are silenced while the guard masks. With routing, replies move onto the capture
/// engine once it runs and move back when the stream ends for any reason.
final class EchoMaskedCapture: AudioCapturing {
    private let capture: any AudioCapturing
    private let echoGuard: AmbientReplyEchoGuard
    private let routing: CaptureReplyRouting?

    init(capture: any AudioCapturing, echoGuard: AmbientReplyEchoGuard, routing: CaptureReplyRouting? = nil) {
        self.capture = capture
        self.echoGuard = echoGuard
        self.routing = routing
    }

    @MainActor
    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        let source = try capture.start()
        routing?.attach()
        let routing = routing
        let echoGuard = echoGuard
        let (stream, continuation) = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .unbounded)
        let forward = Task.detached {
            for await buffer in source {
                echoGuard.silenceIfMasking(buffer.pcmBuffer)
                continuation.yield(buffer)
            }
            await routing?.detach()
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
    func stop() {
        capture.stop()
        routing?.detach()
    }
}
