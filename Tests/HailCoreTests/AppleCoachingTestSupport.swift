import AVFAudio
import Foundation
@testable import HailCore

@MainActor
final class AppleCoachingRig {
    let capture = FakeAudioCapture()
    let time = CoachingTestClock()
    let center = NotificationCenter()
    let event = Notification.Name("SyntheticAppleCoachingLifecycle")
    var outputs = [CoachingObservedPort(uid: "synthetic-wired", kind: .wiredHeadphones)]
    var frameCounts: [UInt32] = []
    var plays = 0
    var cancellations = 0
    var captureBuffers = 0
    var nonzeroCapture = false
    var suspensions: [CoachingSuspension] = []
    var onSnapshot: (() -> Void)?
    var rendererReady = true
    lazy var monitor = CoachingOutputMonitor(snapshot: { [weak self] in
        self?.onSnapshot?()
        return self?.outputs ?? []
    },
                                            center: center, names: [event])

    func make(capture supplied: (any AudioCapturing)? = nil) throws -> ApplePrivateCoaching {
        let source = supplied ?? capture
        let player = CoachingEngineRenderer(operations: .init(ready: { [weak self] in
            guard let self else { return false }
            return self.rendererReady && self.capture.startCount > self.capture.stopCount
        }, schedule: { [weak self] buffer, _ in self?.frameCounts.append(buffer.frameLength) },
           control: { [weak self] command in
            if case .play = command { self?.plays += 1 }
            if case .stop = command { self?.cancellations += 1 }
        }), observe: { [monitor] in monitor.observe() })
        return try ApplePrivateCoaching(capture: source, player: player, monitor: monitor,
                                        listenerID: "private-coach", hooks: .init(buffer: { [weak self] buffer, _ in
            self?.captureBuffers += 1
            let samples = buffer.pcmBuffer.floatChannelData?.pointee
            self?.nonzeroCapture = samples?[1] != 0
        }, suspended: { [weak self] _, reason in self?.suspensions.append(reason) }), clock: time.clock)
    }
}

@MainActor
final class CoachingStartingCapture: AudioCapturing {
    let base = FakeAudioCapture()
    var onStart: (() -> Void)?
    var fails = false
    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        let stream = try base.start()
        onStart?()
        if fails { throw CoachingSafetyError.invalidAudio }
        return stream
    }
    func stop() { base.stop() }
}
