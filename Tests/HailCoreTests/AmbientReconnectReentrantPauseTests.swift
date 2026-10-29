import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReentrantPauseTests {
    @Test func systemEndDuringStopThenTheStreamWatcherClaimsOnlyOnePause() async throws {
        let run = ReentrantPauseRun()
        await run.controller.turnOn(for: try binding())
        run.capture.stop()
        try await waitUntil {
            let releasing = await run.release.isWaiting()
            let pending = await run.steps.pending
            return releasing && pending == 1
        }
        try await waitUntil { await MainActor.run { run.streamer?.isStreaming == false } }
        #expect(run.controller.pausedReason != nil && !run.controller.isListening)
        #expect(run.controller.isOn && run.activity == [true])
        #expect(run.capture.base.startCount == 1 && run.releases == 1)
        await run.release.fire()
        await run.controller.turnOff()
        await run.steps.release()
        try await waitUntil { await run.steps.pending == 0 }
        #expect(!run.controller.isOn && run.releases == 1 && run.activity == [true, false])
    }
}

@MainActor
private final class ReentrantPauseRun {
    let center = NotificationCenter()
    let release = SleepGate()
    let steps = BackoffSteps()
    let capture = ReentrantPauseCapture()
    var releases = 0
    var activity: [Bool] = []
    var streamer: AmbientAudioStreamer?
    lazy var controller = makeController()

    private func makeController() -> AmbientListeningController {
        capture.onStop = { [center] in
            #expect(Thread.isMainThread)
            center.post(name: AVAudioEngineCapture.endedBySystem, object: nil,
                        userInfo: [AVAudioEngineCapture.endedCauseKey: AVAudioEngineCapture.interruptionCause])
        }
        let controller = AmbientListeningController(
            notificationCenter: center, requestPermission: { true },
            makeStreamer: { [self] in
                let streamer = AmbientAudioStreamer(capture: capture, send: $0)
                self.streamer = streamer
                return streamer
            }, releaseSession: { [self] in
                releases += 1
                try? await release.sleep(.zero)
            }, sleep: { [steps] _ in await steps.sleep() }, send: { _, _ in }
        )
        controller.onListeningChange = { [weak self] in self?.activity.append($0) }
        return controller
    }
}

@MainActor
private final class ReentrantPauseCapture: AudioCapturing {
    let base = FakeAudioCapture()
    var onStop: (@MainActor () -> Void)?
    func start() throws -> AsyncStream<AudioCaptureBuffer> { try base.start() }
    func stop() {
        onStop?() // Post synchronously while capture and its stream watcher are both ending.
        base.stop()
    }
}
