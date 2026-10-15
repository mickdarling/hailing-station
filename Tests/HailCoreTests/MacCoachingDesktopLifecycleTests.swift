#if os(macOS)
import AppKit
import AVFAudio
import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingDesktopLifecycleTests {
    @Test func appSwitchKeepsRouteButSleepLogoutAndGraphChangeRevokeIt() async throws {
        let app = NotificationCenter(), workspace = NotificationCenter()
        let monitor = try MacCoachingOutputMonitor(bound: { true }, registrations: [],
            center: app, workspaceCenter: workspace)
        var invalidations = 0
        monitor.onInvalidated = { invalidations += 1 }
        try monitor.arm()
        let before = monitor.observe()
        app.post(name: NSApplication.didResignActiveNotification, object: nil)
        await drainCoachingTasks()
        #expect(monitor.observe() == before && invalidations == 0)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            try monitor.arm()
            workspace.post(name: name, object: nil)
            #expect(monitor.observe() == .unqualified)
            await drainCoachingTasks()
        }
        #expect(invalidations == 2)
        try monitor.arm()
        app.post(name: .AVAudioEngineConfigurationChange, object: nil)
        #expect(monitor.observe() == .unqualified)
        await drainCoachingTasks()
        #expect(invalidations == 3)
    }

    @Test func releaseRemovesWorkspaceObserversWithoutRetainingMonitor() async throws {
        let app = NotificationCenter(), workspace = NotificationCenter()
        var monitor: MacCoachingOutputMonitor? = try MacCoachingOutputMonitor(bound: { true },
            registrations: [], center: app, workspaceCenter: workspace)
        weak var released = monitor
        var invalidations = 0
        monitor?.onInvalidated = { invalidations += 1 }
        try monitor?.arm()
        monitor = nil
        #expect(released == nil)
        released = nil
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        app.post(name: .AVAudioEngineConfigurationChange, object: nil)
        await drainCoachingTasks()
        #expect(invalidations == 0)
    }
}
#endif
