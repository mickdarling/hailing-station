#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore
@testable import StationTalkTestSupport

extension StationBackgroundCaptureTests {
    @Test(arguments: [Departure.windowOccluded, .windowHidden], [false, true])
    func stationTalkRestartsAfterUncoveringWindow(_ departure: Departure, ambientStreaming: Bool) async throws {
        try await expectStationRestart(after: departure, ambientStreaming: ambientStreaming)
    }

    @Test func stationTalkRestartsAfterReturningFromBackground() async throws {
        // Exercise the scenePhase observer shared with iOS. Ambient keeps the root's separate route teardown idle.
        try await expectStationRestart(after: .sceneBackground, ambientStreaming: true)
    }

    private func expectStationRestart(after departure: Departure, ambientStreaming: Bool) async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let root = try #require(scene.probe.root)
        let talk = try await PendingTalk(scene, ambientStreaming: ambientStreaming) { _, _ in
            Issue.record("Hiding Talk must discard the utterance")
        }
        let view = talk.view
        talk.press()
        let first = try #require(view.startTask)
        await first.value
        try #require(view.isRecording && view.talkSession.owner == view.captureOwnerID && talk.tap.startCount == 1)
        try #require(scene.rig.store.ambientStreaming == ambientStreaming)
        let activations = await scene.backend.activationHistory

        try await discardMountedTalk(talk, on: departure)
        #expect(!view.isRecording && talk.tap.stopCount == 1 && view.talkSession.owner == nil)
        #expect(await !talk.speech.isRunning)
        if ambientStreaming {
            #expect(await scene.backend.activationHistory == activations)
            try await scene.expectAmbientContinues(root: root)
        }

        if departure == .sceneBackground {
            scene.host.setScenePhase(.active)
        } else {
            if departure == .windowHidden { scene.host.window.orderBack(nil) }
            talk.setOcclusion(.visible)
        }
        await scene.host.render()
        try #require(talk.probe.buttonIsEnabled)
        talk.press()
        let restarted = try #require(view.startTask)
        await restarted.value
        #expect(view.isRecording && talk.tap.startCount == 2 && view.talkSession.owner == view.captureOwnerID)
        if ambientStreaming { try await scene.expectAmbientContinues(root: root) }
        await view.finish(force: true)
        await scene.rig.close()
    }

    private func discardMountedTalk(_ talk: PendingTalk, on departure: Departure) async throws {
        let view = talk.view, host = talk.scene.host
        if departure == .sceneBackground {
            host.setScenePhase(.inactive)
            await host.render()
            try #require(view.isRecording)
        }
        let consumer = try #require(view.bufferTask)
        let drain = OpenGate()
        // Hold the end of the consumer past capture.stop() so another presentation can try admission mid-teardown.
        view.bufferTask = Task {
            await consumer.value
            await drain.wait()
        }
        if departure == .sceneBackground {
            host.setScenePhase(.background)
        } else {
            if departure == .windowHidden { host.window.orderOut(nil) }
            talk.setOcclusion([])
        }
        await host.render()
        do {
            try await waitUntil { await MainActor.run { !view.isRecording } }
        } catch {
            await drain.release()
            throw error
        }
        let teardown = view.finishTask
        #expect(teardown != nil && view.talkSession.owner == view.captureOwnerID)
        let admitted = view.talkSession.admit(UUID(), receive: { _ in }, cleanup: {})
        #expect(!admitted)
        await drain.release()
        await teardown?.value
    }
}
#endif
