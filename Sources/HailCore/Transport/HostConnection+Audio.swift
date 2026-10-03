public import AVFAudio
public import HailProtocol

/// Wire shape for ambient microphone audio (#203): signed 16-bit little-endian, 16 kHz, mono, interleaved,
/// sent as 100 ms segments over the existing `.audio` frame. Audio bytes are never logged.
public enum AmbientAudioFormat {
    public static let sampleRate = 16_000
    public static let channels = 1
    /// 100 ms: 1,600 frames x 2 bytes.
    public static let chunkBytes = sampleRate / 10 * 2 * channels
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

extension HostConnection {
    /// The host advertises this only when its ambient-listening flags are set (#203).
    public static let streamAudioCapability = "stream_audio"

    /// Sends one ambient microphone segment in the existing `.audio` frame. The host chooses the dispatch
    /// target, so the frame names none. Refused unless the connection is ready and the host advertised
    /// `stream_audio`; reply descriptors belong to host-to-terminal audio and are rejected here.
    public func sendAudio(_ audio: AudioPayload) async throws {
        guard snapshot.state == .ready, let socket else { throw HostConnectionFailure.notReady }
        guard snapshot.capabilities.contains(Self.streamAudioCapability) else {
            throw HostConnectionFailure.unsupportedCapability(Self.streamAudioCapability)
        }
        guard audio.reply == nil, audio.streamID != nil, audio.codec == .pcm16,
              audio.bytes.count <= PayloadLimits.maxAudioBytes else {
            throw HostConnectionFailure.malformed("ambient audio segment is malformed")
        }
        let frame = Frame(
            version: snapshot.negotiatedVersion ?? ProtocolVersion.current,
            timestamp: wallNow(), source: deviceName, payload: .audio(audio)
        )
        try await socket.send(FrameCoding.encode(frame))
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
