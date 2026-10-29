import AVFAudio
import Foundation
@testable import HailCore

@MainActor
final class CallCaptureRig {
    let clock = TestInstantClock()
    let center = NotificationCenter()
    let routeWait = BackoffSteps()
    let retry = BackoffSteps()
    var routeEvaluated = false
    var routePosted = false
    var engines: [AVAudioEngine] = []
    var fakes: [FakeEngineOperations] = []
    var busy = false
    var releases = 0
    lazy var controller = makeController()

    private func makeController() -> AmbientListeningController {
        AmbientListeningController(
        notificationCenter: center, requestPermission: { true },
        makeStreamer: { [weak self] send in
            guard let self else { throw CancellationError() }
            if busy { throw MicBusy() }
            let fake = FakeEngineOperations()
            fakes.append(fake)
            var operations = fake.operations
            operations.isRunning = { [weak self, weak fake] _ in
                if self?.routePosted == true { self?.routeEvaluated = true }
                return fake?.running ?? false
            }
            let engine = AVAudioEngine()
            engines.append(engine)
            let capture = AVAudioEngineCapture(
                engine: engine, notificationCenter: center, operations: operations,
                routeInputChanged: { _ in true }, sleep: { [routeWait] in await routeWait.sleep($0) }
            )
            return AmbientAudioStreamer(capture: capture, send: send)
        }, releaseSession: { [weak self] in self?.releases += 1 },
        sleep: { [retry] in await retry.sleep($0) }, now: { [clock] in clock.now() }, send: { _, _ in }
        )
    }

    func route(_ reason: UInt) {
        routePosted = true
        center.post(name: AudioCaptureEndingSignal.Names.routeChange, object: nil,
                    userInfo: [AudioCaptureEndingSignal.Names.routeChangeReasonKey: reason])
    }
    func interruption(_ began: Bool) {
        center.post(name: AudioCaptureEndingSignal.Names.interruption, object: nil,
                    userInfo: [AudioCaptureEndingSignal.Names.interruptionTypeKey: UInt(began ? 1 : 0)])
    }
    func close() async {
        await controller.turnOff()
        await routeWait.release()
        await retry.release()
    }
}
