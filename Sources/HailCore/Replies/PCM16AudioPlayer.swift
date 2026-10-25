// Reply routing through the capture engine (#269) stays beside the guard/player it changes, within the four-file budget.
// swiftlint:disable file_length
import AVFoundation
public import HailProtocol

public enum ReplyAudioPlayerError: Error, Equatable, Sendable {
    case unsupportedFormat
    case invalidBuffer
}

extension PCM16AudioPlayer: CaptureRoutedReplies {}
extension PCM16AudioPlayer: PlayoutGapReporting {}
extension PCM16AudioPlayer: ReplyCatchUpReporting {}

/// AVAudioEngine renderer for the raw signed 16-bit, mono stream produced by the current vbsay bridge.
@MainActor
public final class PCM16AudioPlayer: ReplyAudioPlaying {
    private let ownEngine = AVAudioEngine()
    /// The engine replies play through: our own, or a voice-processing capture engine while ambient listening runs,
    /// so its echo canceller hears the reply as the far end (#269).
    private var engine: AVAudioEngine
    fileprivate let node = AVAudioPlayerNode()
    private let sourceFormat: AVAudioFormat
    fileprivate var gapMeter = PlayoutGapMeter()
    /// What is queued, and whether a stalled reply is held until it catches up (#825, `ReplyPlayoutBuffer`).
    fileprivate var playout = ReplyPlayoutBuffer()
    /// Bumped whenever the queue is dropped, so completions of buffers from before never count as played.
    fileprivate var playoutGeneration: UInt = 0
    /// Audio queued while holding, not yet handed to the gap meter: the stall is measured when it plays on.
    fileprivate var heldDuration: Duration = .zero
    public var onCatchingUpChanged: (@MainActor (Bool) -> Void)?
    public var isCatchingUp: Bool { playout.isCatchingUp }
    #if os(iOS)
    private var didConfigureAudioSession = false
    #endif

    public init() {
        guard let sourceFormat = PCM16BufferConverter.sourceFormat() else {
            preconditionFailure("Hailing Station PCM playback format is unavailable")
        }
        self.sourceFormat = sourceFormat
        engine = ownEngine
        engine.attach(node)
        // Player buffers must match this output format. The mixer owns conversion to the current
        // hardware route (normally 48 kHz and possibly stereo on iPhone/iPad).
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
    }

    public func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        let buffers = try PCM16PlaybackBuffers.forPayload(payload)
        let wasPlaying = node.isPlaying && engine.isRunning
        try prepare()
        schedule(buffers, onPlayed: onPlayed)
        let wasCatchingUp = playout.isCatchingUp
        guard playout.queued(buffers.map { Self.duration(of: [$0]) }, startsReply: payload.sequence == 0,
                             endsReply: payload.isFinal) else {
            heldDuration += Self.duration(of: buffers) // Held: a stalled reply plays on once it catches up (#825).
            return
        }
        // New audio plays the node even after a pause the controller never resumed (a reply arriving while paused),
        // or after the system stopped it (an interruption): neither stretch was heard as a gap. Playing on after a
        // stall is neither: the stall was heard, and the meter counts it.
        if !wasPlaying, !wasCatchingUp { gapMeter.restarted(at: .now) }
        gapMeter.scheduled(
            heldDuration + Self.duration(of: buffers), at: .now, startsReply: payload.sequence == 0,
            endsReply: payload.isFinal
        )
        heldDuration = .zero
        if !node.isPlaying { node.play() }
        if wasCatchingUp { onCatchingUpChanged?(false) }
    }

    public func pause() {
        node.pause()
        gapMeter.paused(at: .now)
    }

    public func cancel() {
        dropPlayout()
        node.stop()
        node.reset()
        gapMeter.cleared()
    }

    public func resume() throws {
        try prepare()
        gapMeter.resumed(at: .now)
        guard !playout.isCatchingUp else { return } // Still catching up: it plays on when enough is queued (#825).
        node.play()
    }

    public func takePlayoutGaps() -> PlayoutGapMeter.Gaps { gapMeter.take() }

    private static func duration(of buffers: [AVAudioPCMBuffer]) -> Duration {
        buffers.reduce(.zero) { total, buffer in
            total + .seconds(Double(buffer.frameLength) / buffer.format.sampleRate)
        }
    }

    public func setMuted(_ muted: Bool) {
        node.volume = muted ? 0 : 1
        gapMeter.muteChanged(muted, at: .now)
    }

    public func replaceQueue(
        with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?
    ) throws {
        dropPlayout()
        node.stop()
        node.reset()
        gapMeter.cleared()
        try prepare()
        for (index, payload) in payloads.enumerated() {
            let completion = index == payloads.indices.last ? onPlayed : nil
            let buffers = try PCM16PlaybackBuffers.forPayload(payload)
            schedule(buffers, onPlayed: completion)
            _ = playout.queued(buffers.map { Self.duration(of: [$0]) }, startsReply: index == 0,
                               endsReply: payload.isFinal)
            gapMeter.scheduled(
                Self.duration(of: buffers), at: .now, startsReply: index == 0, endsReply: payload.isFinal
            )
        }
        node.play()
    }

    /// Every buffer reports when it has played, so a queue that runs dry mid-reply is seen (#825); the last also
    /// fires `onPlayed`, including when a stop flushes it.
    private func schedule(
        _ buffers: [AVAudioPCMBuffer], onPlayed: (@MainActor @Sendable () -> Void)?
    ) {
        for (index, buffer) in buffers.enumerated() {
            let finished = index == buffers.indices.last ? onPlayed : nil
            let (duration, generation) = (Self.duration(of: [buffer]), playoutGeneration)
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    self?.bufferPlayed(duration, generation: generation)
                    finished?()
                }
            }
        }
    }

    /// Moves playback onto `capture` (a running voice-processing engine), or back to our own engine with nil.
    /// Moving stops whatever is queued; callers do it when listening starts or stops, not mid-reply.
    func route(through capture: AVAudioEngine?) {
        let target = capture ?? ownEngine
        guard target !== engine else { return }
        dropPlayout()
        node.stop()
        gapMeter.cleared()
        engine.detach(node)
        if engine === ownEngine { ownEngine.stop() }
        target.attach(node)
        target.connect(node, to: target.mainMixerNode, format: sourceFormat)
        engine = target
    }

    /// A stall froze `capture`, which was then restarted (#443). Stopping the node fires the completion of any reply
    /// that was playing through it, so the playback queue advances; the next `schedule` plays the node again.
    func captureEngineRestarted(_ capture: AVAudioEngine) {
        guard engine === capture else { return }
        dropPlayout()
        node.stop()
        gapMeter.cleared()
    }

    /// True while replies play through a capture engine's echo canceller.
    var isRoutedThroughCapture: Bool { engine !== ownEngine && engine.isRunning }

    /// Whether playback sits on a capture engine other than `capture` (a newer run's), which an older run's
    /// late detach must leave alone.
    func isOnAnotherCapture(than capture: AVAudioEngine) -> Bool { engine !== ownEngine && engine !== capture }

    private func prepare() throws {
        // A capture engine the system stopped underneath us is never restarted here: that would reopen the mic.
        if engine !== ownEngine, !engine.isRunning { route(through: nil) }
        // On a running capture engine the session is already play-and-record and active (capture set it up).
        // Re-applying the category or activation from the background made the first background reply fail
        // with `playback_failed` on device (#282), so leave the session to its owner.
        if engine !== ownEngine { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // A mixable session is the background keepalive's (#352): play within it. A play-and-record category would
        // interrupt other apps' audio, and iOS refuses that activation in the background.
        if !didConfigureAudioSession, !session.categoryOptions.contains(.mixWithOthers) {
            // Share capture's external-output policy while retaining an audible built-in fallback (#852).
            try AudioOutputSessionRouting.configure(
                session, allowsBluetoothHFP: session.categoryOptions.contains(.allowBluetoothHFP)
            )
            didConfigureAudioSession = true
        }
        try session.setActive(true)
        #endif
        if !engine.isRunning { try engine.start() }
    }
}

/// Smooth stall recovery (#825): the player holds a reply whose queue ran dry until it catches up.
extension PCM16AudioPlayer {
    /// One buffer finished playing. A queue run dry before the reply's final audio holds playback, rather than
    /// letting each late frame play the moment it lands, which is the stutter.
    fileprivate func bufferPlayed(_ duration: Duration, generation: UInt) {
        guard generation == playoutGeneration, playout.played(duration) else { return }
        node.pause()
        onCatchingUpChanged?(true)
    }

    /// The queue is dropped: completions from before never count, and nothing is held.
    fileprivate func dropPlayout() {
        let wasCatchingUp = playout.isCatchingUp
        playout.cleared()
        playoutGeneration &+= 1
        heldDuration = .zero
        if wasCatchingUp { onCatchingUpChanged?(false) }
    }
}

/// Route activation needs a short quiet lead-in before the first speech sample, and the final
/// sample needs output headroom before playback completion can release the reply. Padding only
/// utterance boundaries avoids adding a gap at every streamed chunk.
enum PCM16PlaybackBuffers {
    static let boundaryFrames: AVAudioFrameCount = 2_400 // 100 ms at the player format's 24 kHz.

    static func forPayload(_ payload: AudioPayload) throws -> [AVAudioPCMBuffer] {
        let speech = try PCM16BufferConverter.buffer(payload)
        var buffers: [AVAudioPCMBuffer] = []
        if payload.sequence == 0 { buffers.append(try silence(in: speech.format)) }
        buffers.append(speech)
        if payload.isFinal { buffers.append(try silence(in: speech.format)) }
        return buffers
    }

    private static func silence(in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: boundaryFrames),
              let samples = buffer.floatChannelData?.pointee else {
            throw ReplyAudioPlayerError.invalidBuffer
        }
        for index in 0..<Int(boundaryFrames) { samples[index] = 0 }
        buffer.frameLength = boundaryFrames
        return buffer
    }
}

/// Pure payload conversion kept separate from the hardware-owning player so unit tests never
/// instantiate AVAudioEngine. The player and every returned buffer share this explicit format.
enum PCM16BufferConverter {
    static let sourceSampleRate = 24_000.0

    static func sourceFormat() -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sourceSampleRate, channels: 1)
    }

    static func buffer(_ payload: AudioPayload) throws -> AVAudioPCMBuffer {
        guard payload.codec == .pcm16, payload.channels == 1,
              !payload.bytes.isEmpty,
              payload.bytes.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw ReplyAudioPlayerError.unsupportedFormat
        }
        let count = payload.bytes.count / MemoryLayout<Int16>.size
        guard count <= Int(AVAudioFrameCount.max),
              let inputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: Double(payload.sampleRate),
                  channels: 1, interleaved: false
              ),
              let input = AVAudioPCMBuffer(
                  pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)
              ),
              let destination = input.int16ChannelData?.pointee else {
            throw ReplyAudioPlayerError.invalidBuffer
        }
        payload.bytes.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let offset = index * MemoryLayout<Int16>.size
                let bits = UInt16(source[offset]) | UInt16(source[offset + 1]) << 8
                destination[index] = Int16(bitPattern: bits)
            }
        }
        input.frameLength = AVAudioFrameCount(count)
        guard let sourceFormat = sourceFormat() else { throw ReplyAudioPlayerError.invalidBuffer }
        return try convert(input, to: sourceFormat)
    }

    private static func convert(
        _ input: AVAudioPCMBuffer, to sourceFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: input.format, to: sourceFormat) else {
            throw ReplyAudioPlayerError.unsupportedFormat
        }
        let ratio = sourceFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: capacity) else {
            throw ReplyAudioPlayerError.invalidBuffer
        }
        let converterInput = ConverterInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !converterInput.wasSupplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            converterInput.wasSupplied = true
            inputStatus.pointee = .haveData
            return converterInput.buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            throw ReplyAudioPlayerError.invalidBuffer
        }
        return output
    }
}
