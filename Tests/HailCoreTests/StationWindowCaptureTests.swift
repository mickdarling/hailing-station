#if os(macOS)
import Foundation
import HailProtocol
import Observation
import Testing
@testable import HailCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StationWindowCaptureTests {
    @Test func disposedWindowNeverLeavesTheMicrophoneRunningUnseenDuringASend() async throws {
        try await withWindow { fixture in
            try await fixture.holdAudioSend()
            fixture.closeWindow()
            try await fixture.dismantle()
            try #require(!fixture.menu.windowOpen)
            try await fixture.checkWindowlessCapture()
        }
    }

    @Test func inheritedGlobalTrueWithNoAppValueStillStopsAtClose() async throws {
        let key = "ambient.keepListeningWhenWindowClosed"
        let domain = UUID().uuidString
        let inherited = try #require(UserDefaults(suiteName: domain))
        // Model the global fallback with a private suite in the real app lookup chain.
        inherited.set(true, forKey: key)
        let defaults = UserDefaults.standard
        defaults.addSuite(named: domain)
        defer {
            defaults.removeSuite(named: domain)
            inherited.removePersistentDomain(forName: domain)
        }
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        try #require(defaults.persistentDomain(forName: app)?[key] == nil)
        try #require(defaults.object(forKey: key) as? Bool == true)
        try await withWindow { fixture in
            try await fixture.holdAudioSend()
            let controller = try #require(fixture.connections?.ambientController)
            let binding = try #require(controller.binding)
            fixture.closeWindow()
            #expect(!fixture.capture.isRunning && controller.listeningState == .stopped(.sceneDisposed))
            #expect(fixture.menu.summary == "Station window closed")
            #expect(!fixture.menu.windowOpen && !fixture.menu.canToggleListening && fixture.menu.listening == .off)
            await controller.turnOn(for: binding) // A start that was queued before close.
            #expect(fixture.capture.startCount == 1 && !fixture.capture.isRunning)
            try await fixture.drain()
        }
    }

    @Test func replacementAttachesBeforeTheRetiringWindowDisappears() async throws {
        try await withWindow { first in
            try await first.holdAudioSend()
            let oldStore = try #require(first.connections)
            withObservationTracking { _ = first.menu.listening } onChange: {
                MainActor.assumeIsolated { #expect(!first.capture.isRunning && oldStore.ambientController == nil) }
            }
            try await withWindow(menu: first.menu) { second in
                let newStore = try #require(second.connections)
                let newController = try #require(newStore.ambientController)
                #expect(oldStore !== newStore && first.controller !== newController)
                #expect(second.menu.listening == .off && !first.capture.isRunning)
                #expect(first.controller?.listeningState == .stopped(.sceneDisposed))
                try await second.holdAudioSend()
                first.closeWindow()
                try await first.dismantle()
                #expect(first.menu.windowOpen && first.menu.canToggleListening && first.menu.listening == .listening)
                #expect([oldStore, newStore].compactMap(\.ambientController).count == 1)
                #expect(newStore.ambientController === newController && second.capture.startCount == 1)
                try await first.drain()
                try await waitForAudioTestState { await first.controller == nil }
                #expect(oldStore.ambientController == nil && second.capture.isRunning && newController.isListening)
            }
        }
    }

    @Test func closingSameStoreReplacementStopsCaptureDuringAHeldSend() async throws {
        try await withWindow { fixture in
            try await fixture.holdAudioSend()
            let firstRoot = try #require(fixture.window?.probe.root)
            let store = firstRoot.connections
            let controller = try #require(fixture.controller)
            try #require(store.ambientController === controller)
            let binding = try #require(controller.binding)
            let probe = NativeSceneAmbientProbe(binding: binding)
            let replacement = NativeSceneAmbientHost(resources: firstRoot.station.value, probe: probe,
                                                      menuStatus: fixture.menu)
            await replacement.render()
            #expect(probe.root?.connections === store && probe.root?.ambientDestinationBinding == binding)
            #expect(store.ambientController === controller)

            fixture.closeWindow()
            #expect(probe.stationVisibility == .visible && probe.root?.connections.ambientController === controller)
            #expect(fixture.menu.canToggleListening && fixture.menu.listening == .listening)
            #expect(controller.isListening && fixture.capture.isRunning && fixture.capture.startCount == 1)

            replacement.finish()
            #expect(!fixture.capture.isRunning && controller.listeningState == .stopped(.sceneDisposed))
            #expect(store.ambientController == nil && !fixture.menu.windowOpen && fixture.menu.listening == .off)
            await replacement.dismantle()
            try await fixture.drain()
        }
    }

    @Test func cardAppearingAfterDisposalCannotInstallItsControllerOrCallback() async throws {
        try await withWindow { fixture in
            let store = try #require(fixture.connections)
            let window = try #require(fixture.window)
            window.probe.toolShown = true
            await window.render()
            let appearances = window.probe.appearances
            store.disposeStationScene()
            window.probe.toolShown = false
            await window.render()
            try #require(window.probe.appearances > appearances)
            #expect(store.ambientController == nil && store.onAmbientMovedHere == nil)
            weak var rejected: AmbientListeningController?
            do {
                let candidate = AmbientListeningControllerTests.Harness().controller
                rejected = candidate
                store.ambientController = candidate
            }
            #expect(rejected == nil)
            try await fixture.dismantle()
            try await waitForAudioTestState { await fixture.controller == nil }
            withExtendedLifetime(store) {}
        }
    }

    private func withWindow(menu: StationMenuStatus = StationMenuStatus(),
                            check: (WindowCaptureFixture) async throws -> Void) async throws {
        let fixture = try WindowCaptureFixture(menu: menu)
        do {
            try await fixture.open()
            try await check(fixture)
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }
}
#endif
