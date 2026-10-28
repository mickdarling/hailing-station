import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// The real root extension is compiled through RootDestinationSelectionAdapter. No native audio or navigation.
@MainActor
@Suite(.serialized) struct StationToolAmbientLifetimeTests {
    enum Tool: CaseIterable, Sendable { case macSetup, audio, labs, replyTools }
    enum Loss: CaseIterable, Sendable { case hostRemoval, targetDeselection }

    @Test(arguments: Tool.allCases)
    func pushingAndReturningFromToolKeepsTheSameCapture(_ tool: Tool) async throws {
        let rig = try AmbientReconnectRig()
        let (log, cleanup) = try makeLog()
        defer { cleanup() }
        rig.controller.diagnostics = log
        try await rig.start()
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        let binding = try rig.currentBinding()
        await root.reconcileAmbientDestination() // The station card disappears under each navigation push.
        #expect(rig.controller.isOn && rig.controller.isListening, "Pushing \(tool) stopped listening")
        #expect(rig.controller.binding == binding && rig.released == 0)
        #expect(rig.unexpected.isEmpty && rig.controller.stopReason == nil)
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active) // Return to the card.
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        #expect(log.nextBatch()?.events.contains { $0.name == .ambientStop
            || $0.fields[.reason] == .token("binding_changed") } == false)
        await rig.close()
    }

    @Test(arguments: Loss.allCases)
    func destinationLossWhileToolIsVisibleStillEndsListening(_ loss: Loss) async throws {
        let rig = try AmbientReconnectRig()
        let (log, cleanup) = try makeLog()
        defer { cleanup() }
        rig.controller.diagnostics = log
        try await rig.start()
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        switch loss {
        case .hostRemoval: await rig.store.remove(rig.endpoint.id)
        case .targetDeselection: await root.forgetSelection(preservingRestore: false)
        }
        // The root callback must also work after the card has left the screen, with no second disappearance.
        await root.reconcileAmbientDestination()
        #expect(root.destination == nil)
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.released == 1)
        let stops = (log.nextBatch()?.events ?? []).filter { $0.name == .ambientStop }
        #expect(stops.count == 1 && stops.first?.fields[.reason] == .token("binding_changed"))
        await rig.close()
    }

    @Test func nativeCardDisappearanceCallsTheTestedRootCallback() throws {
        let source = try appSource("StationCard.swift")
        #expect(source.contains(".onDisappear { Task { await reconcileAmbientDestination() } }"))
        #expect(!source.contains("await controller.destinationLost()"))
    }

    private func makeLog() throws -> (DeviceDiagnostics, () -> Void) {
        let suite = "hail-station-tool-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        return (log, { defaults.removePersistentDomain(forName: suite) })
    }

    private func appSource(_ name: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("Apps/Hail-iOS/\(name)"), encoding: .utf8)
    }
}
