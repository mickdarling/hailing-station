#if os(macOS)
import AudioToolbox
import AVFAudio
import Foundation
import Synchronization

/// One callback's owned copy enters a bounded queue; overflow/failure permanently ends this capture.
final class MacCoachingHALInputDelivery: @unchecked Sendable {
    typealias Pull = @Sendable (UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        UnsafePointer<AudioTimeStamp>, AVAudioFrameCount, AVAudioPCMBuffer) -> OSStatus
    private struct State {
        var continuation: AsyncStream<AudioCaptureBuffer>.Continuation?
        var retired = false
    }
    private let state = Mutex(State())
    private let format: AVAudioFormat
    private let pull: Pull
    init(format: AVAudioFormat, pull: @escaping Pull) { self.format = format; self.pull = pull }
    var healthy: Bool { state.withLock { !$0.retired } }

    func arm(_ continuation: AsyncStream<AudioCaptureBuffer>.Continuation) -> Bool {
        state.withLock {
            guard !$0.retired, $0.continuation == nil else { return false }
            $0.continuation = continuation
            return true
        }
    }

    func retire() {
        let old = state.withLock { value -> AsyncStream<AudioCaptureBuffer>.Continuation? in
            value.retired = true
            defer { value.continuation = nil }
            return value.continuation
        }
        old?.finish()
    }

    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                time: UnsafePointer<AudioTimeStamp>, frames: AVAudioFrameCount) -> OSStatus {
        guard state.withLock({ !$0.retired && $0.continuation != nil }) else { return noErr }
        guard frames > 0, frames <= 8_192, Double(frames) <= format.sampleRate / 4,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            retire(); return kAudio_ParamError
        }
        buffer.frameLength = frames
        let result = pull(flags, time, frames, buffer)
        guard result == noErr, buffer.frameLength == frames, let owned = AudioCaptureBuffer(copying: buffer) else {
            retire(); return result == noErr ? kAudio_ParamError : result
        }
        let finished = state.withLock { value -> AsyncStream<AudioCaptureBuffer>.Continuation? in
            guard !value.retired, let continuation = value.continuation else { return nil }
            switch continuation.yield(owned) {
            case .enqueued: return nil
            case .dropped, .terminated:
                value.retired = true
                value.continuation = nil
                return continuation
            @unknown default:
                value.retired = true
                value.continuation = nil
                return continuation
            }
        }
        finished?.finish()
        return noErr
    }
}

private let coachingHALInputCallback: AURenderCallback = { context, flags, time, _, frames, _ in
    return Unmanaged<MacCoachingHALInputDelivery>.fromOpaque(context).takeUnretainedValue()
        .render(flags, time: time, frames: frames)
}

/// Starts only from explicit qualified begin. No default-device write, output, aggregate or automatic restart.
@MainActor final class MacCoachingHALInputCapture: AudioCapturing {
    private let hardware: MacCoachingHALInputUnit
    private var delivery: MacCoachingHALInputDelivery?
    private var started = false
    private var retired = false

    init() throws { hardware = try MacCoachingHALInputUnit() }
    isolated deinit { stop(); hardware.dispose() }
    var healthy: Bool { !retired && (delivery?.healthy ?? true) }
    var binding: MacCoachingBindingOperations { hardware.binding }

    func prepare() throws {
        guard !retired, delivery == nil, !started else { throw CoachingSafetyError.unsafeOutput }
        let format = try hardware.inputFormat()
        let renderer = MacCoachingHALInputRender(unit: hardware.unit)
        let delivery = MacCoachingHALInputDelivery(format: format, pull: { flags, time, frames, buffer in
            renderer.pull(flags, time: time, frames: frames, buffer: buffer)
        })
        self.delivery = delivery
        do {
            try hardware.prepare(format: format, callback: AURenderCallbackStruct(
                inputProc: coachingHALInputCallback, inputProcRefCon: Unmanaged.passUnretained(delivery).toOpaque()))
        } catch { delivery.retire(); hardware.dispose(); retired = true; throw error }
    }

    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        guard !retired, !started, let delivery, delivery.healthy else { throw CoachingSafetyError.unsafeOutput }
        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .bufferingOldest(8))
        pair.continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.stop() } }
        guard delivery.arm(pair.continuation) else { throw CoachingSafetyError.unsafeOutput }
        started = true
        do { try hardware.start() } catch { stop(); throw error }
        guard delivery.healthy else { stop(); throw CoachingSafetyError.unsafeOutput }
        return pair.stream
    }

    func stop() {
        retired = true
        delivery?.retire() // Revoke callback admission before joining hardware stop.
        hardware.stop()
        started = false
    }
}

struct MacCoachingHALInputRender: @unchecked Sendable {
    let unit: AudioUnit
    func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>,
              frames: AVAudioFrameCount, buffer: AVAudioPCMBuffer) -> OSStatus {
        AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
    }
}
#endif
