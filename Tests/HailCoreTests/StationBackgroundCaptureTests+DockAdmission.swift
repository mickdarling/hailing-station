#if os(macOS)
import SwiftUI
import Testing
@testable import HailCore
@testable import StationTalkTestSupport

extension StationBackgroundCaptureTests {
    @Test("D-A1") func coveredDockRefusesTalkUntilUncovered() async throws {
        try await withMountedStationDock { dock in
            dock.occlusion([])
            await dock.expectRefused() // Deliver even a stale intent, before a redraw can disable the button.
            dock.occlusion(.visible)
            await dock.scene.host.render()
            try await dock.expectStartAndFinish()
        }
    }

    @Test("D-A2") func occlusionBeforeDockBeginAlsoRefusesTheNextTap() async throws {
        try await withMountedStationDock { dock in
            let first = try #require(dock.dispatch(.talk))
            dock.occlusion([])
            #expect(dock.dispatch(.talk) == nil)
            let teardown = try #require(dock.view.finishTask)
            await teardown.value
            await first.value
            #expect(first.isCancelled && dock.tap.startCount == 0)
            #expect(dock.view.startTask == nil && dock.view.finishTask == nil)
            await dock.expectRefused()
        }
    }

    @Test("D-A3") func visibleDockRequiresAnActiveScene() async throws {
        try await withMountedStationDock { dock in
            let host = dock.scene.host
            for phase in [ScenePhase.inactive, .background] {
                host.setScenePhase(phase)
                await host.render()
                try #require(host.window.isVisible && host.window.occlusionState.contains(.visible))
                #expect(!dock.probe.buttonIsEnabled)
                await dock.expectRefused()
            }
            host.setScenePhase(.active)
            await host.render()
            try await dock.expectStartAndFinish()
        }
    }

    @Test("D-B1") func dockEscapeBeforeBeginRearmsTalk() async throws {
        try await withMountedStationDock { dock in
            let first = try #require(dock.dispatch(.talk))
            let escape = try #require(dock.view.onEscape)
            dock.view.startInterrupt(using: escape)
            let interrupt = try #require(dock.view.interruptTask)
            await interrupt.value
            await first.value
            #expect(dock.escapes.value == 1 && dock.view.interruptTask == nil)
            try await expectDockRearmedAfterCancellation(dock)
        }
    }

    @Test("D-B2") func forcedFinishBeforeDockBeginRearmsTalk() async throws {
        try await withMountedStationDock { dock in
            let first = try #require(dock.dispatch(.talk))
            await dock.view.finish(force: true)
            #expect(first.isCancelled)
            await first.value
            try await expectDockRearmedAfterCancellation(dock)
        }
    }

    private func expectDockRearmedAfterCancellation(_ dock: MountedStationDock) async throws {
        #expect(dock.view.startTask == nil && dock.view.finishTask == nil && dock.tap.startCount == 0)
        await dock.scene.host.render()
        #expect(dock.probe.buttonIsEnabled)
        // Cancellation has made Talk eligible again. The next dispatch must still consult live visibility.
        dock.occlusion([])
        await dock.expectRefused()
        dock.occlusion(.visible)
        await dock.scene.host.render()
        try await dock.expectStartAndFinish()
        #expect(dock.tap.startCount == 1)
    }

    @Test("D-2", arguments: [false, true])
    func twoDockDispatchesLeaveOneStartForHideToCancel(otherOwner: Bool) async throws {
        try await withMountedStationDock { dock in
            let first = try #require(dock.dispatch(.talk))
            #expect(dock.dispatch(.talk) == nil && dock.view.startTask == first)
            let session = dock.view.talkSession
            let other = UUID()
            if otherOwner { try #require(session.admit(other, receive: { _ in }, cleanup: {})) }
            defer { session.retire(other) }
            dock.scene.host.window.orderOut(nil)
            dock.occlusion([])
            let teardown = try #require(dock.view.finishTask)
            await teardown.value
            await first.value
            #expect(first.isCancelled && dock.tap.startCount == 0 && !dock.view.isRecording)
            #expect(dock.view.startTask == nil && dock.view.finishTask == nil && dock.tap.stopCount == 0)
            #expect(session.owner == (otherOwner ? other : nil))
            #expect(await !dock.speech.isRunning)
        }
    }
}
#endif
