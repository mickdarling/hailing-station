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
        var tapActive = false
        var tapQuietAt: ContinuousClock.Instant?
    }

    /// P4b1 is opt-in and inert: P4b2 must supply fresh flags/window and handle the content-free signal.
    public let segmentOnsetGate: ReplySegmentOnsetGate
    private let onsetTap = Mutex<ReplySegmentOnsetTap?>(nil)
    private let state = Mutex(State())
    private let route = ReplyRoute()
    private let tail: Duration
    private let now: Now
    @MainActor public weak var diagnostics: DeviceDiagnostics?

    public init(tail: Duration = defaultTail, now: @escaping Now = { ContinuousClock.now }) {
        self.tail = tail
        self.now = now
        segmentOnsetGate = ReplySegmentOnsetGate(tail: tail, now: now)
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

    /// Tap capture always masks ambient, including when replies use echo cancellation (#935).
    /// An off edge starts the same tail as reply masking; repeated reports never extend it.
    @MainActor
    func setTapCaptureActive(_ active: Bool) {
        let instant = now()
        let changed = state.withLock { state in
            guard state.tapActive != active else { return false }
            state.tapActive = active
            state.tapQuietAt = active ? nil : instant.advanced(by: tail)
            return true
        }
        guard changed else { return }
        var fields: [DiagnosticField: DiagnosticValue] = [
            .state: .token(active ? "tap_to_talk_start" : "tap_to_talk_end"), .on: .boolean(active)
        ]
        if !active { fields[.ms] = .integer(Int64(tail / .milliseconds(1))) }
        diagnostics?.record(.echoGuard, fields)
    }

    /// True while either masking reason or its tail holds.
    public var isMasking: Bool {
        let instant = now()
        return state.withLock { state in
            if state.tapActive || state.tapQuietAt.map({ instant < $0 }) == true { return true }
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
        route.player = player as? any CaptureRoutedReplies
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
        let routing = CaptureReplyRouting(engine: engine, route: route, echoGuard: self, cancelsEcho: true)
        return EchoMaskedCapture(capture: Self.watchingForStalls(capture, routing), echoGuard: self, routing: routing)
    }

    /// Ambient engines restart themselves when they stall (#443). A restart also drops a reply the stall froze on
    /// the same engine, so the playback queue and the guard's masking move on instead of waiting forever.
    @MainActor
    static func watchingForStalls(_ capture: any AudioCapturing, _ routing: CaptureReplyRouting) -> any AudioCapturing {
        guard let engineCapture = capture as? AVAudioEngineCapture else { return capture }
        if engineCapture.stallPolicy == nil { engineCapture.stallPolicy = .ambient }
        engineCapture.onEngineRestarted = { [weak routing] in routing?.engineRestarted() }
        return engineCapture
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
            let capture = Self.watchingForStalls(plainCapture(engine), routing)
            return EchoMaskedCapture(capture: capture, echoGuard: self, routing: routing)
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

extension AmbientReplyEchoGuard {
    public func configureSegmentOnset(
        input: @escaping @Sendable () -> ReplySegmentOnsetInput, onOnset: @escaping @Sendable () -> Void
    ) {
        onsetTap.withLock { $0 = ReplySegmentOnsetTap(input: input, onOnset: onOnset) }
        segmentOnsetGate.closeWindow()
    }

    public func stopSegmentOnset() {
        onsetTap.withLock { $0 = nil }
        segmentOnsetGate.closeWindow()
    }

    func observeSegmentOnset(_ buffer: AVAudioPCMBuffer) {
        guard let tap = onsetTap.withLock({ $0 }) else { return }
        if segmentOnsetGate.analyse(buffer, input: tap.input()) { tap.onOnset() }
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

    /// The guarded player's gap counts (#737), when it keeps them: the app's reply player is always wrapped.
    var gapReporter: (any PlayoutGapReporting)? { player as? any PlayoutGapReporting }

    func setTapCaptureActive(_ active: Bool) { echoGuard.setTapCaptureActive(active) }

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
    @MainActor weak var player: (any CaptureRoutedReplies)?

    nonisolated init() {}
}

/// A reply player that can play through a capture engine (#269): `PCM16AudioPlayer`, or a test double.
@MainActor
protocol CaptureRoutedReplies: AnyObject {
    func route(through capture: AVAudioEngine?)
    var isRoutedThroughCapture: Bool { get }
    func isOnAnotherCapture(than capture: AVAudioEngine) -> Bool
    /// `capture` was stopped and started again after a stall (#443): if replies play through it, drop whatever the
    /// stall froze, firing its completions, so the next reply plays.
    func captureEngineRestarted(_ capture: AVAudioEngine)
}

/// Moves replies onto a running capture engine and back again, keeping the guard's routing flag truthful. The
/// flag means "echo-cancelled", so a plain engine (`cancelsEcho: false`) never lowers masking.
@MainActor
final class CaptureReplyRouting {
    private let engine: AVAudioEngine
    private let route: ReplyRoute
    private let echoGuard: AmbientReplyEchoGuard
    let cancelsEcho: Bool

    init(engine: AVAudioEngine, route: ReplyRoute, echoGuard: AmbientReplyEchoGuard, cancelsEcho: Bool) {
        self.engine = engine
        self.route = route
        self.echoGuard = echoGuard
        self.cancelsEcho = cancelsEcho
    }

    func attach() {
        guard let player = route.player else { return echoGuard.setRoutedThroughCapture(false) }
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

    /// The engine restarted after a stall (#443): a reply frozen on it is dropped so playback and masking move on.
    func engineRestarted() {
        route.player?.captureEngineRestarted(engine)
    }
}

/// Ambient capture whose buffers are silenced while the guard masks. With routing, replies move onto the capture
/// engine once it runs and move back when the stream ends for any reason.
final class EchoMaskedCapture: AudioCapturing {
    private let capture: any AudioCapturing
    private let echoGuard: AmbientReplyEchoGuard
    let routing: CaptureReplyRouting?

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
                echoGuard.observeSegmentOnset(buffer.pcmBuffer)
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

private struct ReplySegmentOnsetTap: Sendable {
    let input: @Sendable () -> ReplySegmentOnsetInput
    let onOnset: @Sendable () -> Void
}

/// Fresh capture-time authorization. P4b2 owns opening/closing the played P4a window; nil is closed.
public struct ReplySegmentOnsetInput: Sendable {
    public let window: Range<ContinuousClock.Instant>?
    public let ambientListening: Bool
    public let privacyOn: Bool
    public let settings: ReplySegmentSettings

    public init(
        window: Range<ContinuousClock.Instant>?, ambientListening: Bool, privacyOn: Bool,
        settings: ReplySegmentSettings = .init()
    ) {
        self.window = window
        self.ambientListening = ambientListening
        self.privacyOn = privacyOn
        self.settings = settings
    }
}

/// Counts only, ordered <−60, [−60,−45), [−45,−35), [−35,−25), [−25,0] dBFS.
public struct ReplyOnsetHistogram: Sendable {
    public private(set) var counts = [UInt64](repeating: 0, count: 5)

    mutating func record(_ level: Double) {
        let bucket = level < -60 ? 0 : level < -45 ? 1 : level < -35 ? 2 : level < -25 ? 3 : 4
        counts[bucket] &+= 1
    }
}

public struct ReplyOnsetDiagnostics: Sendable {
    public fileprivate(set) var onsets: UInt64 = 0
    public fileprivate(set) var withoutAdmittedRequest: UInt64 = 0
    public fileprivate(set) var levels = ReplyOnsetHistogram()
    public fileprivate(set) var floors = ReplyOnsetHistogram()
}

/// Scalar detector state only: no PCM, transcripts, reply identities or pre-roll survive an analyse call.
private struct ReplyOnsetWindow {
    let range: Range<ContinuousClock.Instant>
    var lastEnd: ContinuousClock.Instant
    var calibrationSeconds = 0.0
    var calibrationEnergy = 0.0
    var sustainedSeconds = 0.0
    var fired = false
}

/// Inert energy gate, v1 pending Mick. It never yields, unmasks, sends or advertises.
public final class ReplySegmentOnsetGate: Sendable {
    private struct State {
        var window: ReplyOnsetWindow?
        var diagnostics = ReplyOnsetDiagnostics()
        // Diagnostic timestamps only, separate from disposable detection state. Expired entries are pruned
        // on every analysis/read/admission; no audio or identities are kept here.
        var pending: [ContinuousClock.Instant] = []

        mutating func expire(at instant: ContinuousClock.Instant) {
            diagnostics.withoutAdmittedRequest &+= UInt64(pending.count { instant >= $0 })
            pending.removeAll { instant >= $0 }
        }
    }

    private let state = Mutex(State())
    private let tail: Duration
    private let now: AmbientReplyEchoGuard.Now
    private static let calibration = 0.2
    private static let margin = 6.0

    init(tail: Duration, now: @escaping AmbientReplyEchoGuard.Now) {
        self.tail = tail
        self.now = now
    }

    /// P4b2 must also call this on window close, without waiting for another capture buffer.
    public func closeWindow() { state.withLock { $0.window = nil } }

    public var diagnostics: ReplyOnsetDiagnostics {
        let instant = now()
        return state.withLock { state in
            state.expire(at: instant)
            return state.diagnostics
        }
    }

    /// P4b2 supplies a genuinely admitted ambient request, not a capture/transcription attempt.
    /// One request satisfies all preceding onsets still within their individual five-second deadlines.
    public func ambientRequestAdmitted() {
        let instant = now()
        state.withLock { state in
            state.expire(at: instant)
            state.pending.removeAll()
        }
    }

    func analyse(_ buffer: AVAudioPCMBuffer, input: ReplySegmentOnsetInput) -> Bool {
        let instant = now()
        return state.withLock { state in
            state.expire(at: instant)
            guard input.ambientListening, !input.privacyOn, let range = input.window,
                  instant > range.lowerBound, instant <= range.upperBound,
                  buffer.frameLength > 0, buffer.format.sampleRate > 0 else {
                state.window = nil
                return false
            }
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            let start = instant.advanced(by: .seconds(-seconds))
            var window = state.window ?? ReplyOnsetWindow(range: range, lastEnd: max(start, range.lowerBound))
            if window.range != range {
                window = ReplyOnsetWindow(range: range, lastEnd: max(start, range.lowerBound))
            }
            let fired = consume(buffer, end: instant, window: &window, state: &state, settings: input.settings)
            state.window = window
            return fired
        }
    }
}

private extension ReplySegmentOnsetGate {
    private func consume(
        _ buffer: AVAudioPCMBuffer, end: ContinuousClock.Instant, window: inout ReplyOnsetWindow,
        state: inout State, settings: ReplySegmentSettings
    ) -> Bool {
        let rate = buffer.format.sampleRate
        let start = end.advanced(by: .seconds(-Double(buffer.frameLength) / rate))
        let eligible = max(window.lastEnd, window.range.lowerBound.advanced(by: tail))
        var first = max(0, Int(ceil(Double(start.duration(to: eligible) / .seconds(1)) * rate - 0.000001)))
        let count = Int(buffer.frameLength)
        guard first < count, !window.fired else { return false }
        if start > window.lastEnd.advanced(by: .seconds(1 / rate)) {
            window.sustainedSeconds = 0
            // Missing capture during calibration cannot stand in for measured floor audio.
            if window.calibrationSeconds < Self.calibration {
                window.calibrationSeconds = 0
                window.calibrationEnergy = 0
            }
        }
        window.lastEnd = end
        guard calibrate(buffer, first: &first, window: &window, diagnostics: &state.diagnostics),
              first < count, let power = Self.power(buffer, frames: first..<count) else {
            window.sustainedSeconds = 0
            return false
        }
        let level = Self.dbfs(power)
        let floor = Self.dbfs(window.calibrationEnergy / window.calibrationSeconds)
        state.diagnostics.levels.record(level)
        if level + 0.000001 >= max(settings.onsetThresholdDBFS, floor + Self.margin) {
            window.sustainedSeconds += Double(count - first) / rate
        } else {
            window.sustainedSeconds = 0
        }
        guard window.sustainedSeconds + 0.000001 >= settings.sustainedOnset else { return false }
        window.fired = true
        state.diagnostics.onsets &+= 1
        state.pending.append(end.advanced(by: .seconds(5)))
        return true
    }

    func calibrate(
        _ buffer: AVAudioPCMBuffer, first: inout Int, window: inout ReplyOnsetWindow,
        diagnostics: inout ReplyOnsetDiagnostics
    ) -> Bool {
        guard window.calibrationSeconds < Self.calibration else { return true }
        let rate = buffer.format.sampleRate
        let needed = Int(ceil((Self.calibration - window.calibrationSeconds) * rate - 0.000001))
        let last = min(Int(buffer.frameLength), first + needed)
        guard let power = Self.power(buffer, frames: first..<last) else {
            window.calibrationSeconds = 0
            window.calibrationEnergy = 0
            return false
        }
        let duration = Double(last - first) / rate
        window.calibrationEnergy += power * duration
        window.calibrationSeconds += duration
        first = last
        guard window.calibrationSeconds + 0.000001 >= Self.calibration else { return false }
        diagnostics.floors.record(Self.dbfs(window.calibrationEnergy / window.calibrationSeconds))
        return true
    }

    static func dbfs(_ power: Double) -> Double { power > 0 ? 10 * log10(power) : -.infinity }

    /// Normalized RMS power, including every channel. Unsupported or nonfinite PCM fails closed.
    static func power(_ buffer: AVAudioPCMBuffer, frames: Range<Int>) -> Double? {
        guard !frames.isEmpty else { return nil }
        var sum = 0.0
        var samples = 0
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = channel.mData else { return nil }
            let channels = Int(channel.mNumberChannels)
            for index in (frames.lowerBound * channels)..<(frames.upperBound * channels) {
                guard let value = sample(data, index: index, format: buffer.format.commonFormat),
                      value.isFinite else { return nil }
                sum += min(1, value * value)
                samples += 1
            }
        }
        return samples > 0 ? sum / Double(samples) : nil
    }

    static func sample(_ data: UnsafeMutableRawPointer, index: Int, format: AVAudioCommonFormat) -> Double? {
        switch format {
        case .pcmFormatFloat32: return Double(data.assumingMemoryBound(to: Float.self)[index])
        case .pcmFormatFloat64: return data.assumingMemoryBound(to: Double.self)[index]
        case .pcmFormatInt16: return Double(data.assumingMemoryBound(to: Int16.self)[index]) / 32_768
        case .pcmFormatInt32: return Double(data.assumingMemoryBound(to: Int32.self)[index]) / 2_147_483_648
        default: return nil
        }
    }
}
