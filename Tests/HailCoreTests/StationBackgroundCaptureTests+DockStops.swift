#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore
@testable import StationTalkTestSupport

extension StationBackgroundCaptureTests {
    @Test("D-S1", arguments: [false, true])
    func backgroundDiscardsDockRecording(ambientStreaming: Bool) async throws {
        try await withMountedStationDock(ambientStreaming: ambientStreaming) { dock in
            try await recordDockUtterance(dock)
            dock.scene.host.setScenePhase(.background)
            await dock.scene.host.render()
            try await expectDockDiscard(dock)
            if ambientStreaming {
                let root = try #require(dock.scene.probe.root)
                try await dock.scene.expectAmbientContinues(root: root)
            }
        }
    }

    enum DockWindowDeparture: CaseIterable, Sendable { case occlude, minimize, hide }

    @Test("D-S2", arguments: DockWindowDeparture.allCases)
    func windowDepartureDiscardsDockRecordingUntilVisible(_ departure: DockWindowDeparture) async throws {
        try await withMountedStationDock { dock in
            let window = dock.scene.host.window
            if departure == .minimize {
                window.styleMask.formUnion([.titled, .miniaturizable])
                dock.occlusion(.visible)
                await dock.scene.host.render()
            }
            try await recordDockUtterance(dock)
            switch departure {
            case .occlude:
                try #require(window.isVisible)
            case .minimize:
                window.miniaturize(nil)
                try await waitUntil { await MainActor.run { window.isMiniaturized } }
            case .hide:
                window.orderOut(nil)
                try #require(!window.isVisible)
            }
            dock.occlusion([])
            await dock.scene.host.render()
            try await expectDockDiscard(dock)
            #expect(!dock.probe.buttonIsEnabled)
            await dock.expectRefused()
            if departure == .minimize {
                window.deminiaturize(nil)
                try await waitUntil { await MainActor.run { !window.isMiniaturized } }
            }
            window.orderBack(nil)
            dock.occlusion(.visible)
            await dock.scene.host.render()
            try await dock.expectStartAndFinish()
        }
    }

    private func recordDockUtterance(_ dock: MountedStationDock) async throws {
        let start = try #require(dock.dispatch(.talk))
        await start.value
        try #require(dock.tap.startCount == 1 && dock.view.isRecording)
        try #require(dock.view.recordingDestination != nil && dock.view.talkSession.owner == dock.view.captureOwnerID)
        try dock.tap.yield(sineBuffer())
        try await waitUntil { await dock.speech.consumedBuffers == 1 }
        await dock.speech.emit(.init(text: "fixture request", isFinal: true))
        try await waitUntil { await MainActor.run { dock.view.finalText == "fixture request" } }
    }

    private func expectDockDiscard(_ dock: MountedStationDock) async throws {
        await dock.view.finishTask?.value
        #expect(dock.tap.stopCount == 1 && !dock.view.isRecording && dock.view.talkSession.owner == nil)
        #expect(dock.view.bufferTask == nil && dock.view.startTask == nil && dock.view.finishTask == nil)
        #expect(await dock.speech.cancelCount == 1)
        #expect(await !dock.speech.isRunning)
        let frames = try await dock.scene.rig.socket.sentFrames()
        #expect(!frames.contains { if case .text = $0.payload { true } else { false } })
    }
}
#endif
