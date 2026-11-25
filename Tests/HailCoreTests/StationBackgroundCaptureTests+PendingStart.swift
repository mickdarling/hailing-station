#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore
@testable import StationTalkTestSupport

extension StationBackgroundCaptureTests {
    @Test(arguments: [ScenePhase.inactive, .active])
    func talkRechecksSceneAfterSpeechPreparation(_ phase: ScenePhase) async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let root = try #require(scene.probe.root)
        let preparing = CompletionFlag(), resume = OpenGate()
        let speech = FakeTranscriber {
            await preparing.set()
            await resume.wait()
        }
        let talk = try await PendingTalk(scene, speech: speech)
        let view = talk.view
        talk.press()
        let start = try #require(view.startTask)
        do {
            try await waitUntil { await preparing.isSet }
        } catch {
            await resume.release()
            throw error
        }
        #expect(view.talkSession.owner == view.captureOwnerID && talk.tap.startCount == 0)
        let activations = await scene.backend.activationHistory
        scene.host.setScenePhase(phase)
        await scene.host.render()
        #expect(!start.isCancelled)
        await resume.release()
        await start.value

        #expect(view.startTask == nil)
        if phase == .inactive {
            #expect(talk.tap.startCount == 0 && !view.isRecording)
            #expect(view.talkSession.owner == nil)
            #expect(await !speech.isRunning)
        } else {
            #expect(talk.tap.startCount == 1 && view.isRecording)
            #expect(view.talkSession.owner == view.captureOwnerID)
        }
        #expect(await scene.backend.activationHistory == activations)
        try await scene.expectAmbientContinues(root: root)
        if view.isRecording { await view.finish() }
        await scene.rig.close()
    }

    @Test func hidingBeforeBeginRetiresTheStartAndAllowsAnotherTalk() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let talk = try await PendingTalk(scene)
        let view = talk.view

        // Retain the real consumer's liveness closure. Once its stream ends it reads only transitioning().
        talk.press()
        let warmup = try #require(view.startTask)
        await warmup.value
        let consumer = try #require(view.bufferTask)
        talk.tap.stop()
        await consumer.value
        let transitioning = try #require(CapturePlaybackSuppression.liveness[view.captureOwnerID])
        await view.finish()
        await scene.host.render()
        let previousStarts = talk.tap.startCount
        try #require(previousStarts == 1 && !transitioning())
        view.beginCaptureExclusivity()
        try #require(talk.playback.isCaptureSuppressed)

        // Both actions run on the main actor without a suspension, before the installed start can enter begin().
        talk.press()
        let start = try #require(view.startTask)
        let teardown = try talk.occlude()
        #expect(start.isCancelled)
        await teardown.value
        #expect(view.startTask == nil && !view.isForcedTeardown && !view.playbackRestoreRequested)
        #expect(!view.ownsCaptureSuppression && !talk.playback.isCaptureSuppressed && !transitioning())
        #expect(talk.tap.startCount == previousStarts && !view.isRecording)
        #expect(await !talk.speech.isRunning)

        talk.setOcclusion(.visible)
        await scene.host.render()
        talk.press()
        let restarted = try #require(view.startTask)
        await restarted.value
        #expect(view.isRecording && talk.tap.startCount == previousStarts + 1)
        await view.finish()
        await scene.rig.close()
    }

    @Test func twoTalkActivationsLeaveOnlyOneStartForHideToCancel() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let talk = try await PendingTalk(scene)
        talk.press()
        let first = try #require(talk.view.startTask)
        talk.press()
        let installed = try #require(talk.view.startTask)
        #expect(installed == first)
        let teardown = try talk.occlude()
        #expect(first.isCancelled)
        await teardown.value
        await first.value
        await installed.value
        #expect(talk.tap.startCount == 0 && !talk.view.isRecording)
        #expect(talk.tap.stopCount == 0)
        #expect(await !talk.speech.isRunning)
        await scene.rig.close()
    }
}

@MainActor
struct PendingTalk {
    let scene: BackgroundCaptureScene
    let tap: FakeAudioCapture
    let speech: FakeTranscriber
    let playback: ReplyPlaybackController
    let view: StationTalkTestSupport.StationTranscriptionView
    let probe: MountedTalkProbe

    init(_ scene: BackgroundCaptureScene, ambientStreaming: Bool = true, speech: FakeTranscriber = FakeTranscriber(),
         onFinalized: (@MainActor (String, PastedDraft?) async throws -> Void)? = nil) async throws {
        self.scene = scene
        let root = try #require(scene.probe.root)
        if ambientStreaming {
            try await root.audioRoutes.activate()
            await scene.rig.controller.turnOn(for: scene.binding)
            try #require(scene.rig.store.ambientStreaming)
        }
        let tap = FakeAudioCapture()
        self.tap = tap
        self.speech = speech
        let playback = root.playback
        self.playback = playback
        playback.captureLivenessSleep = { _ in throw CancellationError() }
        let probe = MountedTalkProbe()
        self.probe = probe
        scene.host.window.fixtureOcclusion = .visible
        let session = StationTalkTestSupport.StationTalkSession {
            StationTalkTestSupport.TranscriptionResources(capture: tap, transcriber: speech)
        }
        scene.probe.talkSurface = AnyView(StationTalkTestSupport.StationTranscriptionView(
            audioSession: root.audioRoutes,
            onCaptureWillBegin: { CapturePlaybackSuppression.begin($0, using: playback) },
            onCaptureDidEnd: { CapturePlaybackSuppression.end($0, using: playback, resuming: $1) },
            onCaptureTeardownCompleted: { CapturePlaybackSuppression.markCleanupComplete($0, using: playback) },
            onFinalized: onFinalized
        ).sharingTalkSession(session).environment(probe))
        await scene.host.render()
        view = try #require(probe.view)
        try #require(probe.press != nil)
        try #require(view.scenePhase == .active && !view.isRecording)
    }

    func press() { probe.press?() }

    func setOcclusion(_ state: NSWindow.OcclusionState) {
        scene.host.window.fixtureOcclusion = state
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: scene.host.window)
    }

    func occlude() throws -> Task<Void, Never> {
        setOcclusion([])
        return try #require(view.finishTask)
    }
}
#endif
