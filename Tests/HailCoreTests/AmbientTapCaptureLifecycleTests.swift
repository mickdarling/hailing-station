import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// The app's actual stream consumer (symlinked into this test target), with synthetic engine/session IO.
@MainActor
@Suite struct AmbientTapCaptureMaskLifecycleTests {
    @Test(arguments: [false, true])
    func normalTerminationReleasesMaskAndReplySuppression(inBackground: Bool) async throws {
        let source = FakeAudioCapture()
        let rig = TapCaptureLifecycleRig(capture: source)
        await rig.view.begin()
        #expect(rig.view.isRecording)
        #expect(rig.playback.isCaptureSuppressed)
        #expect(rig.echoGuard.isMasking)
        let consumer = try #require(rig.view.bufferTask)
        if inBackground { rig.view.scenePhase = .background }
        source.stop()
        await consumer.value
        rig.expectReleased(labFinished: false)
        #expect(rig.view.sent.isEmpty)
    }

    @Test func systemEndedStreamReleasesMaskAndReplySuppression() async throws {
        let center = NotificationCenter()
        let engine = FakeEngineOperations()
        let capture = AVAudioEngineCapture(
            engine: AVAudioEngine(), notificationCenter: center, operations: engine.operations
        )
        let rig = TapCaptureLifecycleRig(capture: capture)
        let livenessClock = TapCaptureLivenessClock()
        livenessClock.install(on: rig.playback)
        await rig.view.begin()
        let consumer = try #require(rig.view.bufferTask)
        #expect(engine.running)
        center.post(name: AudioCaptureEndingSignal.Names.interruption, object: nil,
                    userInfo: [AudioCaptureEndingSignal.Names.interruptionTypeKey: UInt(1)])
        await consumer.value
        #expect(!engine.running)
        #expect(rig.playback.isCaptureSuppressed)
        // Round-1 reproduction: the real watcher heals a system end even while the UI flag stays set.
        // Advance only its sleep and await the heal itself, independently of main-actor scheduling delays.
        #expect(await livenessClock.advanceUntilHeal(using: rig.playback) == 1)
        #expect(!rig.playback.isCaptureSuppressed)
        #expect(livenessClock.intervals == [.seconds(1)])
        rig.expectReleased(labFinished: false)
        #expect(rig.view.sent.isEmpty)
    }

    @Test func cancelledConsumerReleasesMaskAndReplySuppression() async throws {
        let rig = TapCaptureLifecycleRig(capture: FakeAudioCapture())
        await rig.view.begin()
        let consumer = try #require(rig.view.bufferTask)
        consumer.cancel()
        await consumer.value
        rig.expectReleased(labFinished: false)
    }

    @Test func failedConsumerReleasesMaskAndReplySuppression() async throws {
        let source = FakeAudioCapture()
        let transcriber = TapLifecycleTranscriber()
        await transcriber.configure(failBuffers: true)
        let rig = TapCaptureLifecycleRig(capture: source, transcriber: transcriber)
        await rig.view.begin()
        let consumer = try #require(rig.view.bufferTask)
        try source.yield(sineBuffer())
        await consumer.value
        #expect(await !transcriber.stopping)
        rig.expectReleased(labFinished: false)
    }

    @Test func reconciliationUsesEndedStreamWhileRecordingFlagStillAwaitsCleanup() async throws {
        let source = FakeAudioCapture()
        let transcriber = TapLifecycleTranscriber()
        let rig = TapCaptureLifecycleRig(capture: source, transcriber: transcriber)
        await rig.view.begin()
        let consumer = try #require(rig.view.bufferTask)
        source.stop()
        await consumer.value
        #expect(rig.view.isRecording) // Cleanup is deferred to Finish; this UI flag must not keep the stream live.
        #expect(await !transcriber.stopping)
        #expect(CapturePlaybackSuppression.liveness[rig.view.captureOwnerID]?() == false)
        #expect(CapturePlaybackSuppression.reconcile(using: rig.playback) == 1)
        rig.expectReleased(labFinished: false)
    }

    @Test func explicitFinishDoesNotWaitOnItself() async throws {
        let rig = TapCaptureLifecycleRig(capture: FakeAudioCapture())
        await rig.view.begin()
        await rig.view.finish()
        rig.expectReleased()
    }

    @Test func interruptDoesNotWaitOnItself() async throws {
        let rig = TapCaptureLifecycleRig(capture: FakeAudioCapture())
        await rig.view.begin()
        await rig.view.interruptTarget(using: {})
        rig.expectReleased()
    }

    @Test(arguments: [false, true])
    func lateCancelledConsumerCannotReleaseReplacementCapture(failsAfterReplacement: Bool) async throws {
        let source = FakeAudioCapture()
        let transcriber = TapLifecycleTranscriber()
        await transcriber.configure(failBuffers: failsAfterReplacement, holdConsume: true)
        let rig = TapCaptureLifecycleRig(capture: source, transcriber: transcriber)
        await rig.view.begin()
        let oldConsumer = try #require(rig.view.bufferTask)
        try source.yield(sineBuffer())
        try await waitUntil { await transcriber.consuming }
        await rig.view.interruptTarget(using: {})
        await rig.view.begin()
        let replacement = try #require(rig.view.bufferTask)
        await transcriber.releaseConsume()
        await oldConsumer.value
        #expect(rig.view.isRecording)
        #expect(rig.view.status == "Listening")
        #expect(CapturePlaybackSuppression.reconcile(using: rig.playback) == 0)
        #expect(rig.playback.isCaptureSuppressed)
        #expect(CapturePlaybackSuppression.liveness[rig.view.captureOwnerID]?() == true)
        rig.clock.advance(by: .seconds(1))
        #expect(rig.echoGuard.isMasking)
        replacement.cancel()
        await replacement.value
        rig.expectReleased(labFinished: false)
    }

    @Test func forcedTeardownKeepsItsHoldUntilSessionCleanupCompletes() async throws {
        let source = FakeAudioCapture()
        let rig = TapCaptureLifecycleRig(capture: source)
        await rig.view.begin()
        let consumer = try #require(rig.view.bufferTask)
        rig.view.audioSession.holdDeactivation = true
        let teardown = Task { await rig.view.finish(force: true) }
        try await waitUntil { await rig.view.audioSession.deactivating }
        source.stop()
        await consumer.value
        #expect(rig.view.isRecording)
        #expect(CapturePlaybackSuppression.liveness[rig.view.captureOwnerID]?() == true)
        #expect(CapturePlaybackSuppression.reconcile(using: rig.playback) == 0)
        #expect(rig.playback.isCaptureSuppressed)
        rig.view.audioSession.releaseDeactivation()
        await teardown.value
        rig.expectReleased()
    }

    @Test func backgroundCleanupStartsTailBeforeDeferredReplyRestore() async throws {
        let rig = TapCaptureLifecycleRig(capture: FakeAudioCapture())
        await rig.view.begin()
        rig.view.scenePhase = .background
        await rig.view.finish(force: true)
        #expect(!rig.view.isRecording)
        #expect(rig.playback.isCaptureSuppressed)
        rig.clock.advance(by: .milliseconds(400))
        #expect(!rig.echoGuard.isMasking)
        rig.view.scenePhase = .active
        rig.view.restorePlaybackAfterForcedTeardown()
        #expect(!rig.playback.isCaptureSuppressed)
    }
}

@MainActor
private final class TapCaptureLifecycleRig {
    let clock = EchoGuardClock()
    let echoGuard: AmbientReplyEchoGuard
    let playback: ReplyPlaybackController
    let view: TranscriptionLabView

    init(capture: any AudioCapturing, transcriber: any Transcriber = FakeTranscriber()) {
        let echoGuard = AmbientReplyEchoGuard(now: { [clock] in clock.now })
        let playback = ReplyPlaybackController(player: echoGuard.guarding(DuplexPlayer()))
        self.echoGuard = echoGuard
        self.playback = playback
        view = TranscriptionLabView(capture: capture, playback: playback, transcriber: transcriber)
    }

    func expectReleased(labFinished: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(view.isRecording == !labFinished, sourceLocation: sourceLocation)
        #expect((view.bufferTask == nil) == labFinished, sourceLocation: sourceLocation)
        #expect(view.ownsCaptureSuppression == !labFinished, sourceLocation: sourceLocation)
        CapturePlaybackSuppression.reconcile(using: playback)
        #expect(!playback.isCaptureSuppressed, sourceLocation: sourceLocation)
        #expect(!CapturePlaybackSuppression.hasLedger(for: playback), sourceLocation: sourceLocation)
        #expect(CapturePlaybackSuppression.liveness[view.captureOwnerID] == nil, sourceLocation: sourceLocation)
        clock.advance(by: .milliseconds(399))
        #expect(echoGuard.isMasking, sourceLocation: sourceLocation)
        clock.advance(by: .milliseconds(1))
        #expect(!echoGuard.isMasking, sourceLocation: sourceLocation)
    }
}
