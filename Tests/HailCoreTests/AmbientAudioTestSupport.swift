import Foundation
import AVFAudio
import HailProtocol
import Testing
@testable import HailCore

@MainActor
final class FakeAudioCapture: AudioCapturing {
    private var continuation: AsyncStream<AudioCaptureBuffer>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        guard continuation == nil else { throw AudioCaptureError.alreadyRunning }
        startCount += 1
        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .unbounded)
        continuation = pair.continuation
        return pair.stream
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func yield(_ buffer: AVAudioPCMBuffer) throws {
        let owned = try #require(AudioCaptureBuffer(copying: buffer))
        continuation?.yield(owned)
    }
}

actor SentAudio {
    private(set) var payloads: [AudioPayload] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding: Bool

    init(holding: Bool = false) { self.holding = holding }

    func send(_ payload: AudioPayload) async {
        if holding { await withCheckedContinuation { held.append($0) } }
        payloads.append(payload)
    }

    func release() {
        holding = false
        let waiters = held
        held.removeAll()
        waiters.forEach { $0.resume() }
    }

    func isHolding() -> Bool { !held.isEmpty }
}

/// 100 ms of a 1 kHz sine at half scale, in the 48 kHz float format a typical iPhone route delivers.
func sineBuffer(
    frames: AVAudioFrameCount = 4_800, sampleRate: Double = 48_000, offset: Int = 0
) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        samples[index] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(offset + index) / sampleRate))
    }
    return buffer
}

/// Recorded by a test's `beforeEncode` hook to count buffers reaching the converter.
let encodeMarker = AudioPayload(codec: .pcm16, sampleRate: 16_000, channels: 1, sequence: 0, bytes: Data())
