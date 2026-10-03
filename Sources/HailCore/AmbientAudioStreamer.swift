public import AVFAudio
public import Foundation
public import HailProtocol
public import Observation

// swiftlint:disable file_length
/// Wire shape for ambient microphone audio (#203): signed 16-bit little-endian, 16 kHz, mono, interleaved,
/// sent as 100 ms segments over the existing `.audio` frame. Audio bytes are never logged.
public enum AmbientAudioFormat {
    public static let sampleRate = 16_000
    public static let channels = 1
    /// 100 ms: 1,600 frames x 2 bytes.
    public static let chunkBytes = sampleRate / 10 * 2 * channels
    /// The host gate's raw per-segment ceiling (#205); segments are far below it.
    public static let maxSegmentBytes = 8 * 1_024
    /// Pending segments allowed before the oldest is dropped: one second of audio.
    public static let maxBacklogChunks = 10

    public static func outputFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
    }
}

public enum AmbientAudioError: Error, Equatable, Sendable {
    case unsupportedFormat
    case conversionFailed
}

/// Converts arbitrary microphone buffers to the ambient wire format and slices them into fixed segments.
/// Confined to the single pump task that owns it; the converter is rebuilt when the input route's format changes.
struct AmbientAudioEncoder {
    let streamID: UUID
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var pending = Data()
    private(set) var nextSequence = 0

    init(streamID: UUID) throws {
        guard let format = AmbientAudioFormat.outputFormat() else { throw AmbientAudioError.unsupportedFormat }
        self.streamID = streamID
        outputFormat = format
    }

    /// Returns every complete segment the buffer completes. A partial tail waits for the next buffer.
    mutating func encode(_ buffer: AVAudioPCMBuffer) throws -> [AudioPayload] {
        if let converter, converter.inputFormat != buffer.format { try flushConverter() }
        if converter == nil {
            guard let created = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw AmbientAudioError.unsupportedFormat
            }
            created.downmix = true
            converter = created
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let input = ConverterInput(buffer)
        let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        pending.append(try run(converter, capacity: capacity) { _, status in
            status.pointee = input.wasSupplied ? .noDataNow : .haveData
            defer { input.wasSupplied = true }
            return input.wasSupplied ? nil : input.buffer
        })
        return takeSegments(includingTail: false)
    }

    /// Flushes converter latency and returns the remaining segments; the last one carries `final: true`.
    mutating func finish() throws -> [AudioPayload] {
        try flushConverter()
        return takeSegments(includingTail: true)
    }

    private mutating func flushConverter() throws {
        guard let converter else { return }
        self.converter = nil
        pending.append(try run(converter, capacity: 1_024) { _, status in
            status.pointee = .endOfStream
            return nil
        })
    }

    /// An empty closing segment for a stream whose remaining audio could not be converted.
    mutating func finalMarker() -> AudioPayload { payload(Data(), isFinal: true) }

    private mutating func takeSegments(includingTail: Bool) -> [AudioPayload] {
        var segments: [AudioPayload] = []
        let size = AmbientAudioFormat.chunkBytes
        while pending.count >= size {
            let bytes = Data(pending.prefix(size))
            pending.removeFirst(size)
            segments.append(payload(bytes, isFinal: false))
        }
        if includingTail {
            segments.append(payload(pending, isFinal: true))
            pending = Data()
        }
        return segments
    }

    private mutating func payload(_ bytes: Data, isFinal: Bool) -> AudioPayload {
        defer { nextSequence += 1 }
        return AudioPayload(
            codec: .pcm16, sampleRate: AmbientAudioFormat.sampleRate, channels: AmbientAudioFormat.channels,
            sequence: nextSequence, streamID: streamID, isFinal: isFinal, bytes: bytes
        )
    }

    private func run(
        _ converter: AVAudioConverter, capacity: AVAudioFrameCount, input: @escaping AVAudioConverterInputBlock
    ) throws -> Data {
        var output = Data()
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AmbientAudioError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error, withInputFrom: input)
            if status == .error || error != nil { throw AmbientAudioError.conversionFailed }
            if buffer.frameLength > 0, let samples = buffer.int16ChannelData {
                output.append(Data(bytes: samples[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size))
            }
            guard status == .haveData, buffer.frameLength > 0 else { return output }
        }
    }
}

/// Serial sender with a bounded backlog. When more than `maxPending` segments wait behind a slow socket, the
/// oldest is dropped so latency stays bounded; sequence numbers keep the gap visible to the host.
actor AmbientAudioSendQueue {
    typealias Send = @Sendable (AudioPayload) async throws -> Void
    typealias FailureHandler = @Sendable () async -> Void

    private let send: Send
    private let onFailure: FailureHandler
    private let maxPending: Int
    private var pending: [AudioPayload] = []
    private var draining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var droppedCount = 0
    private(set) var failure: (any Error)?

    init(maxPending: Int, send: @escaping Send, onFailure: @escaping FailureHandler) {
        self.maxPending = maxPending
        self.send = send
        self.onFailure = onFailure
    }

    var hasFailed: Bool { failure != nil }

    func enqueue(_ payload: AudioPayload) {
        guard failure == nil else { return }
        pending.append(payload)
        while pending.count > maxPending, let oldest = pending.first, !oldest.isFinal {
            pending.removeFirst()
            droppedCount += 1
        }
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    func waitUntilIdle() async {
        guard draining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func drain() async {
        while failure == nil, !pending.isEmpty {
            let next = pending.removeFirst()
            do {
                try await send(next)
            } catch {
                failure = error
                pending.removeAll()
                await onFailure()
            }
        }
        draining = false
        idleWaiters.forEach { $0.resume() }
        idleWaiters.removeAll()
    }
}

/// Streams the microphone to a host as ambient audio (#203). It reuses the injected capture seam instead of
/// owning an audio session: `ManagedAudioSession` still activates and configures the session, and the caller
/// decides when streaming may run (PR 5 limits it to the foreground). One stream identity per `start()`;
/// sequence numbers start at zero and `stop()` always ends the stream with a `final: true` segment unless the
/// sender has already failed. A send failure (for example a host without `stream_audio`) stops capture.
@MainActor
@Observable
public final class AmbientAudioStreamer {
    public typealias Send = @Sendable (AudioPayload) async throws -> Void
    public typealias StreamIdentity = @Sendable () -> UUID

    @ObservationIgnored private let capture: any AudioCapturing
    @ObservationIgnored private let send: Send
    @ObservationIgnored private let makeStreamID: StreamIdentity
    @ObservationIgnored private let maxBacklogChunks: Int
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var queue: AmbientAudioSendQueue?

    /// True from `start()` until the stream has sent its final segment or its sender failed.
    public private(set) var isStreaming = false
    public private(set) var streamID: UUID?

    public init(
        capture: any AudioCapturing,
        maxBacklogChunks: Int = AmbientAudioFormat.maxBacklogChunks,
        makeStreamID: @escaping StreamIdentity = { UUID() },
        send: @escaping Send
    ) {
        self.capture = capture
        self.maxBacklogChunks = maxBacklogChunks
        self.makeStreamID = makeStreamID
        self.send = send
    }

    /// Dropping the owner must not leave the microphone streaming: capture stops, which lets the pump flush and
    /// send the final segment on its own.
    deinit {
        guard pump != nil else { return }
        let capture = capture
        Task { @MainActor in capture.stop() }
    }

    /// Engine capture with voice processing so reply playback is echo-cancelled rather than re-streamed.
    /// Call after `ManagedAudioSession` has activated a play-and-record session.
    public static func voiceProcessingCapture(engine: AVAudioEngine = AVAudioEngine()) throws -> AVAudioEngineCapture {
        try engine.inputNode.setVoiceProcessingEnabled(true)
        return AVAudioEngineCapture(engine: engine)
    }

    /// Segments dropped because the send backlog exceeded one second.
    public var droppedChunkCount: Int { get async { await queue?.droppedCount ?? 0 } }
    /// The send error that ended the current or last stream, if any.
    public var failure: (any Error)? { get async { await queue?.failure } }

    public func start() throws {
        guard pump == nil else { throw AudioCaptureError.alreadyRunning }
        let identity = makeStreamID()
        let encoder = try AmbientAudioEncoder(streamID: identity)
        let buffers = try capture.start()
        // Ending capture on a send failure finishes the buffer stream, so the pump exits without new audio.
        let queue = AmbientAudioSendQueue(maxPending: maxBacklogChunks, send: send) { [weak self] in
            await self?.stopCapture(ifCurrent: identity)
        }
        self.queue = queue
        streamID = identity
        isStreaming = true
        pump = Task.detached { [weak self] in
            await Self.pump(buffers, encoder: encoder, queue: queue)
            await self?.stopCapture(ifCurrent: identity, finished: true)
        }
    }

    /// Stops capture, flushes the converter, sends the final segment, and waits for the backlog to drain.
    public func stop() async {
        guard let pump else { return }
        capture.stop()
        await pump.value
    }

    private func stopCapture(ifCurrent identity: UUID, finished: Bool = false) {
        guard streamID == identity, pump != nil else { return }
        capture.stop()
        if finished { pump = nil; isStreaming = false }
    }

    private nonisolated static func pump(
        _ buffers: AsyncStream<AudioCaptureBuffer>, encoder initial: AmbientAudioEncoder, queue: AmbientAudioSendQueue
    ) async {
        var encoder = initial
        var converted = true
        for await buffer in buffers {
            guard !(await queue.hasFailed), let segments = try? encoder.encode(buffer.pcmBuffer) else {
                converted = false
                break
            }
            for segment in segments { await queue.enqueue(segment) }
        }
        let tail = converted ? ((try? encoder.finish()) ?? [encoder.finalMarker()]) : [encoder.finalMarker()]
        for segment in tail { await queue.enqueue(segment) }
        await queue.waitUntilIdle()
    }
}
