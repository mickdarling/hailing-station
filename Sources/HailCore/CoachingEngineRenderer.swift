import AVFAudio
import Foundation
import HailProtocol

enum CoachingRenderControl { case play, pause, stop, muted(Bool) }

@MainActor
struct CoachingRenderOperations {
    var ready: () -> Bool
    var schedule: (AVAudioPCMBuffer, (@MainActor @Sendable () -> Void)?) -> Void
    var control: (CoachingRenderControl) -> Void

    static func live(engine: AVAudioEngine) -> Self {
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: PCM16BufferConverter.sourceFormat())
        return Self(ready: { engine.isRunning && node.engine === engine }, schedule: { buffer, completion in
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                if let completion { Task { @MainActor in completion() } }
            }
        }, control: { command in
            switch command {
            case .play: if !node.isPlaying { node.play() }
            case .pause: node.pause()
            case .stop: node.stop(); node.reset()
            case .muted(let muted): node.volume = muted ? 0 : 1
            }
        })
    }
}

/// Dedicated node on the capture owner's engine. Never starts an engine, activates/configures AVAudioSession,
/// chooses an output or moves onto a fallback engine. An unsupported route cancels, not restarts, playback.
@MainActor
final class CoachingEngineRenderer: CoachingAudioPlaying {
    private let operations: CoachingRenderOperations
    private let observe: () -> CoachingOutputObservation

    init(operations: CoachingRenderOperations, observe: @escaping () -> CoachingOutputObservation) {
        self.operations = operations
        self.observe = observe
    }

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        let token = try ready()
        let buffer = try convert(payload)
        guard try ready() == token else { throw CoachingSafetyError.unsafeOutput }
        operations.schedule(buffer, onPlayed)
        guard try ready() == token else { cancel(); throw CoachingSafetyError.unsafeOutput }
        operations.control(.play)
    }

    func resume() throws { _ = try ready(); operations.control(.play) }
    func pause() { operations.control(.pause) }
    func cancel() { operations.control(.stop) }
    func setMuted(_ muted: Bool) {
        guard (try? ready()) != nil else { cancel(); return }
        operations.control(.muted(muted))
    }

    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        guard !payloads.isEmpty, payloads.count <= 32 else { throw CoachingSafetyError.queueFull }
        let token = try ready()
        let buffers = try payloads.map(convert)
        guard try ready() == token else { throw CoachingSafetyError.unsafeOutput }
        cancel()
        for (index, buffer) in buffers.enumerated() {
            guard try ready() == token else { cancel(); throw CoachingSafetyError.unsafeOutput }
            operations.schedule(buffer, index == buffers.count - 1 ? onPlayed : nil)
        }
        guard try ready() == token else { cancel(); throw CoachingSafetyError.unsafeOutput }
        operations.control(.play)
    }

    private func ready() throws -> UUID {
        guard operations.ready(), case .verifiedHeadphones(let token) = observe() else {
            cancel()
            throw CoachingSafetyError.unsafeOutput
        }
        return token
    }

    private func convert(_ payload: AudioPayload) throws -> AVAudioPCMBuffer {
        guard payload.codec == .pcm16, payload.sampleRate == 24_000, payload.channels == 1,
              payload.sequence >= 0, !payload.bytes.isEmpty, payload.bytes.count <= 48_000,
              payload.bytes.count.isMultiple(of: 2) else { throw CoachingSafetyError.invalidAudio }
        return try PCM16BufferConverter.buffer(payload)
    }
}
