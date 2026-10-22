import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Regression guard for #735 (key 1's review of #808): safety after a haild restart rests on the app. A restarted
/// haild is a new connection, and a new connection is a new binding (`connectionGeneration`). The app must then turn
/// listening off with cause `binding_changed` and never start it again by itself, so nothing records until the owner
/// turns listening on again, and then the host starts public. Pins existing behaviour only. Synthetic only.
@MainActor
@Suite struct AmbientBindingChangeRegressionTests {
    private func diagnostics() throws -> (DeviceDiagnostics, () -> Void) {
        let suite = "hail-735-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:], wallNow: { 1_000 },
                                    clock: { ContinuousClock().now })
        log.setEnabled(true)
        return (log, { defaults.removePersistentDomain(forName: suite) })
    }

    private func names(_ log: DeviceDiagnostics) -> [DiagnosticEvent] {
        (log.nextBatch()?.events ?? []).filter { $0.name == .ambientStart || $0.name == .ambientStop }
    }

    /// The same host and target on a new connection generation (a reconnect, or a restarted haild) is a different
    /// binding.
    @Test func aNewConnectionGenerationIsANewBinding() throws {
        let first = try binding()
        let reconnected = AmbientAudioBinding(hostID: first.hostID, targetID: first.targetID,
                                              connectionGeneration: UUID(), selection: first.selection)
        #expect(reconnected != first)
    }

    /// A reconnect turns listening off with cause `binding_changed`, in the foreground or the background, and the
    /// new binding never starts it again.
    @Test(arguments: [AmbientScene.active, .background])
    func aReconnectTurnsListeningOffAndItStaysOff(_ scene: AmbientScene) async throws {
        let (log, cleanUp) = try diagnostics()
        defer { cleanUp() }
        let harness = AmbientListeningControllerTests.Harness()
        let controller = harness.controller
        controller.diagnostics = log
        let first = try binding()
        await controller.turnOn(for: first)
        #expect(controller.isListening)
        let reconnected = AmbientAudioBinding(hostID: first.hostID, targetID: first.targetID,
                                              connectionGeneration: UUID(), selection: first.selection)
        await controller.update(binding: reconnected, scene: scene)
        #expect(!controller.isOn && !controller.isListening)
        #expect(controller.stopReason?.contains("connection changed") == true)
        for later in [AmbientScene.active, .background, .active] {
            await controller.update(binding: reconnected, scene: later)
        }
        #expect(!controller.isOn && !controller.isListening)
        #expect(harness.capture.startCount == 1)
        let events = names(log)
        #expect(events.map(\.name) == [.ambientStart, .ambientStop])
        #expect(events.last?.fields[.reason] == .token("binding_changed"))
    }

    /// The connection going away (no binding at all) ends listening the same way.
    @Test func aLostConnectionTurnsListeningOff() async throws {
        let (log, cleanUp) = try diagnostics()
        defer { cleanUp() }
        let harness = AmbientListeningControllerTests.Harness()
        harness.controller.diagnostics = log
        await harness.controller.turnOn(for: try binding())
        await harness.controller.update(binding: nil, scene: .active)
        #expect(!harness.controller.isOn && !harness.controller.isListening)
        #expect(names(log).last?.fields[.reason] == .token("binding_changed"))
    }

    /// Off on every launch: a fresh controller given a ready binding, through every scene, never starts listening.
    @Test func listeningNeverStartsOnLaunchOrReconnect() async throws {
        let (log, cleanUp) = try diagnostics()
        defer { cleanUp() }
        let harness = AmbientListeningControllerTests.Harness()
        harness.controller.diagnostics = log
        let ready = try binding()
        for scene in [AmbientScene.active, .inactive, .background, .active] {
            await harness.controller.update(binding: ready, scene: scene)
        }
        await harness.controller.update(binding: try binding(), scene: .active)
        #expect(!harness.controller.isOn && !harness.controller.isListening)
        #expect(harness.capture.startCount == 0)
        #expect(names(log).isEmpty)
    }
}
