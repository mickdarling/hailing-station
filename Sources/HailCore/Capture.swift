public import AVFAudio

/// Events a trigger emits as the user speaks. Push-to-talk, wake phrase, continuous, and intent-gate
/// triggers all produce this same stream (#5, #51).
public enum TriggerEvent: Sendable, Equatable {
    case utteranceStarted
    case utteranceFinal(String)
    case cancelled
}

/// How an utterance begins and ends. The rest of the pipeline never knows which trigger is active (#5).
public protocol Trigger: Sendable {
    var events: AsyncStream<TriggerEvent> { get }
}

/// An owned snapshot of one engine callback buffer, safe to hand to another concurrency domain.
public struct AudioCaptureBuffer: @unchecked Sendable {
    public let pcmBuffer: AVAudioPCMBuffer

    public init?(copying buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return nil }
        pcmBuffer = copy
    }
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case alreadyRunning
}

/// Produces microphone buffers without deciding what they mean. Triggers and transcribers consume this seam (#5, #6).
public protocol AudioCapturing: Sendable {
    @MainActor func start() throws -> AsyncStream<AudioCaptureBuffer>
    @MainActor func stop()
}

/// AVAudioEngine-backed capture for the native terminal. The audio session remains owned by AudioSessionController.
@MainActor
public final class AVAudioEngineCapture: AudioCapturing {
    private let engine: AVAudioEngine
    private var continuation: AsyncStream<AudioCaptureBuffer>.Continuation?
    private var hasTap = false

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public func start() throws -> AsyncStream<AudioCaptureBuffer> {
        guard !engine.isRunning, continuation == nil else { throw AudioCaptureError.alreadyRunning }

        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .unbounded)
        let streamContinuation = pair.continuation
        continuation = streamContinuation
        streamContinuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.stop() }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable buffer, _ in
            guard let ownedBuffer = AudioCaptureBuffer(copying: buffer) else { return }
            streamContinuation.yield(ownedBuffer)
        }
        hasTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        return pair.stream
    }

    public func stop() {
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
