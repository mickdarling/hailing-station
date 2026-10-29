import AVFAudio
import Foundation
import Testing
@testable import HailCore

@MainActor
final class CallPolicyCapture: AudioCapturing {
    private var continuation: AsyncStream<AudioCaptureBuffer>.Continuation?
    private var admission: AudioCaptureAdmission?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        guard continuation == nil else {
            throw AudioCaptureError.alreadyRunning
        }
        admission = AudioCaptureAdmission.current
        startCount += 1
        let pair = AsyncStream<AudioCaptureBuffer>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func yield(_ buffer: AVAudioPCMBuffer) throws {
        if admission?.isPaused == true {
            return
        }
        continuation?.yield(try #require(AudioCaptureAdmission.copy(buffer, through: admission)))
    }
}

/// Generated PCM only: no device capture, recordings or elapsed-time waits.
func callPolicyBuffer(frames: AVAudioFrameCount = 4_800) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        samples[index] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(index) / 48_000))
    }
    return buffer
}
