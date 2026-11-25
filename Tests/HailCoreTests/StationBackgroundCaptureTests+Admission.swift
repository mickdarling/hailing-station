#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import StationTalkTestSupport

extension StationBackgroundCaptureTests {
    @Test func escapeBeforeBeginRetiresTheRejectedStart() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let talk = try await PendingTalk(scene)

        talk.press()
        let first = try #require(talk.view.startTask)
        talk.view.startInterrupt {}
        let interrupt = try #require(talk.view.interruptTask)
        await interrupt.value
        await first.value
        #expect(talk.view.startTask == nil && talk.tap.startCount == 0)

        await scene.host.render()
        #expect(talk.probe.buttonIsEnabled)
        try await talk.expectStartAndFinish(after: first)
        await scene.rig.close()
    }

    @Test func forcedFinishBeforeBeginRetiresTheRejectedStart() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let talk = try await PendingTalk(scene)

        talk.press()
        let first = try #require(talk.view.startTask)
        await talk.view.finish(force: true)
        await first.value
        #expect(talk.view.startTask == nil && talk.tap.startCount == 0)

        await scene.host.render()
        try await talk.expectStartAndFinish(after: first)
        await scene.rig.close()
    }

    @Test func coveredTalkRefusesCaptureUntilUncovered() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let talk = try await PendingTalk(scene)

        talk.setOcclusion([])
        await talk.pressAndExpectNoCapture()
        talk.setOcclusion(.visible)
        await scene.host.render()
        try await talk.expectStartAndFinish()
        await scene.rig.close()
    }

    @Test func occlusionBetweenPressAndBeginAlsoBlocksTheNextPress() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let talk = try await PendingTalk(scene)

        talk.press()
        let first = try #require(talk.view.startTask)
        let teardown = try talk.occlude()
        await teardown.value
        await first.value
        #expect(talk.tap.startCount == 0 && talk.view.startTask == nil)
        #expect(talk.view.finishTask == nil && !talk.view.isRecording)

        await scene.host.render()
        await talk.pressAndExpectNoCapture()
        await scene.rig.close()
    }

    @Test func visibleTalkRequiresAnActiveScene() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let talk = try await PendingTalk(scene)

        for phase in [ScenePhase.inactive, .background] {
            scene.host.setScenePhase(phase)
            await scene.host.render()
            try #require(scene.host.window.isVisible && scene.host.window.occlusionState.contains(.visible))
            await talk.pressAndExpectNoCapture()
        }
        scene.host.setScenePhase(.active)
        await scene.host.render()
        try await talk.expectStartAndFinish()
        await scene.rig.close()
    }
}

private extension PendingTalk {
    func pressAndExpectNoCapture() async {
        press()
        #expect(view.startTask == nil)
        await view.startTask?.value
        #expect(tap.startCount == 0 && !view.isRecording)
        #expect(view.startTask == nil && view.finishTask == nil)
        if view.isRecording { await view.finish() }
    }

    func expectStartAndFinish(after previous: Task<Void, Never>? = nil) async throws {
        press()
        let start = try #require(view.startTask)
        #expect(start != previous)
        await start.value
        #expect(tap.startCount == 1 && view.isRecording)
        await view.finish()
        #expect(!view.isRecording && view.finishTask == nil && view.startTask == nil)
        #expect(await !speech.isRunning)
    }
}
#endif
