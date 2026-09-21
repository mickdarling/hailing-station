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

    public init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
    }

    public func schedule(_ payload: AudioPayload) throws {
        try prepare()
        node.scheduleBuffer(try buffer(payload))
        if !node.isPlaying { node.play() }
    }

    public func pause() {
        node.pause()
    }

    public func resume() throws {
        try prepare()
        node.play()
    }

    public func setMuted(_ muted: Bool) {
        node.volume = muted ? 0 : 1
    }

    public func replaceQueue(with payloads: [AudioPayload]) throws {
        node.stop()
        node.reset()
        try prepare()
        for payload in payloads { node.scheduleBuffer(try buffer(payload)) }
        node.play()
    }

    private func prepare() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        if !engine.isRunning { try engine.start() }
    }

    private func buffer(_ payload: AudioPayload) throws -> AVAudioPCMBuffer {
        guard payload.codec == .pcm16, payload.channels == 1,
              payload.bytes.count.isMultiple(of: MemoryLayout<Int16>.size),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: Double(payload.sampleRate),
                  channels: 1, interleaved: false
              ) else { throw ReplyAudioPlayerError.unsupportedFormat }
        let count = payload.bytes.count / MemoryLayout<Int16>.size
        guard count <= Int(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let destination = buffer.int16ChannelData?.pointee else {
            throw ReplyAudioPlayerError.invalidBuffer
        }
        payload.bytes.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress else { return }
            destination.update(from: source, count: count)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }
}
