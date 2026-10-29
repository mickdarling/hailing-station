import Foundation
import HailProtocol
import Testing
import SwiftUI
@testable import HailCore

/// Real SwiftUI navigation and the shipped card lifetime; audio and transport use model fixtures.
@MainActor
@Suite(.serialized) struct StationToolAmbientLifetimeTests {
    enum Tool: CaseIterable, Sendable { case macSetup, audio, labs, replyTools }
    enum Loss: CaseIterable, Sendable { case hostRemoval, targetDeselection, targetRemoval, hostDisconnect }

    @Test(arguments: Tool.allCases)
    func pushingAndReturningFromToolKeepsTheSameCapture(_ tool: Tool) async throws {
        let rig = try AmbientReconnectRig()
        let (log, cleanup) = try makeLog()
        defer { cleanup() }
        rig.controller.diagnostics = log
        try await rig.start()
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        let binding = try rig.currentBinding()
        var completed = false
        let host = NativeStationToolHost(AmbientListeningCard(connections: rig.store, reconcileDestination: {
            await root.reconcileAmbientDestination()
            completed = true
        }, content: try makeNativeAmbientCard(rig: rig, diagnostics: log)))
        defer { host.finish() }
        try await host.appeared()
        host.push()
        try await waitUntil { await MainActor.run { completed || rig.released > 0 } }
        #expect(rig.controller.isOn && rig.controller.isListening, "Pushing \(tool) stopped listening")
        #expect(rig.controller.binding == binding && rig.released == 0)
        #expect(rig.unexpected.isEmpty && rig.controller.stopReason == nil)
        try await host.back()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        if rig.controller.isListening {
            try await rig.feed()
            try await waitUntil { try await !audioFrames(rig.socket).isEmpty }
        }
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
        await root.reconcileAmbientDestination() // Push a tool before the later loss, with no second disappearance.
        #expect(rig.controller.isListening)
        switch loss {
        case .hostRemoval: await rig.store.remove(rig.endpoint.id)
        case .targetDeselection: await root.forgetSelection(preservingRestore: false)
        case .targetRemoval:
            try await rig.socket.push(.targets([]))
            try await waitUntil { await MainActor.run { root.ambientDestinationBinding == nil } }
        case .hostDisconnect: await rig.store.disconnect(rig.endpoint.id)
        }
        // The root callback must also work after the card has left the screen, with no second disappearance.
        await root.reconcileAmbientDestination()
        #expect(root.destination == nil)
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.released == 1)
        let stops = (log.nextBatch()?.events ?? []).filter { $0.name == .ambientStop }
        #expect(stops.count == 1 && stops.first?.fields[.reason] == .token("binding_changed"))
        await rig.close()
    }

    @Test func disappearanceDuringAndAfterBackgroundRestoreKeepsListening() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        try await rig.drop()
        root.scenePhase = .background
        await rig.controller.update(binding: nil, scene: .background)
        await root.reconcileAmbientDestination()
        #expect(rig.controller.isListening && rig.controller.reconnect.isPending)
        try await rig.reconnect()
        #expect(root.acceptAppliedAmbientRestore())
        await root.reconcileAmbientDestination()
        #expect(rig.controller.isListening && rig.controller.binding == root.ambientDestinationBinding)
        #expect(rig.capture.startCount == 1 && rig.released == 0)
        await rig.close()
    }

    private func makeLog() throws -> (DeviceDiagnostics, () -> Void) {
        let suite = "hail-station-tool-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        return (log, { defaults.removePersistentDomain(forName: suite) })
    }
}
