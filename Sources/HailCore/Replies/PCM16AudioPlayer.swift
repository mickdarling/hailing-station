import AVFoundation
public import HailProtocol

public enum ReplyAudioPlayerError: Error, Equatable, Sendable {
    case unsupportedFormat
    case invalidBuffer
}

/// AVAudioEngine renderer for the raw signed 16-bit, mono stream produced by the current vbsay bridge.
@MainActor
public final class PCM16AudioPlayer: ReplyAudioPlaying {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let sourceFormat: AVAudioFormat
    #if os(iOS)
    private var didConfigureAudioSession = false
    #endif

    public init() {
        guard let sourceFormat = PCM16BufferConverter.sourceFormat() else {
            preconditionFailure("Hailing Station PCM playback format is unavailable")
        }
        self.sourceFormat = sourceFormat
        engine.attach(node)
        // Player buffers must match this output format. The mixer owns conversion to the current
        // hardware route (normally 48 kHz and possibly stereo on iPhone/iPad).
        engine.connect(node, to: engine.mainMixerNode, format: sourceFormat)
    }

    public func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        let buffers = try PCM16PlaybackBuffers.forPayload(payload)
        try prepare()
        schedule(buffers, onPlayed: onPlayed)
        if !node.isPlaying { node.play() }
    }

    public func pause() {
        node.pause()
    }

    public func cancel() {
        node.stop()
        node.reset()
    }

    public func resume() throws {
        try prepare()
        node.play()
    }

    public func setMuted(_ muted: Bool) {
        node.volume = muted ? 0 : 1
    }

    public func replaceQueue(
        with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?
    ) throws {
        node.stop()
        node.reset()
        try prepare()
        for (index, payload) in payloads.enumerated() {
            let completion = index == payloads.indices.last ? onPlayed : nil
            schedule(try PCM16PlaybackBuffers.forPayload(payload), onPlayed: completion)
        }
        node.play()
    }

    private func schedule(
        _ buffers: [AVAudioPCMBuffer], onPlayed: (@MainActor @Sendable () -> Void)?
    ) {
        for (index, buffer) in buffers.enumerated() {
            if index == buffers.indices.last, let onPlayed {
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    Task { @MainActor in onPlayed() }
                }
            } else {
                node.scheduleBuffer(buffer)
            }
        }
    }

    private func prepare() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if !didConfigureAudioSession {
            // Replies may arrive without a preceding capture session. Configure a complete route
            // here as well as in AVAudioSessionBackend so playAndRecord does not default to the
            // receiver, while still allowing a user-selected A2DP output such as AirPods.
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker]
            if session.categoryOptions.contains(.allowBluetoothHFP) {
                options.insert(.allowBluetoothHFP)
            }
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            didConfigureAudioSession = true
        }
        try session.setActive(true)
        #endif
        if !engine.isRunning { try engine.start() }
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
