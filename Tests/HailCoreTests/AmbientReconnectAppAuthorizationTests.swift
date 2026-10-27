import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Mirrors the root's synchronous applied-binding predicate and pending-card fallback, not native SwiftUI.
@MainActor
@Suite(.serialized) struct AmbientReconnectAppAuthorizationTests {
    @Test func backgroundRestoreMustKeepListeningAfterPendingCardDisappears() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let original = try rig.currentBinding()
        var rootAuthorizedGeneration = original.connectionGeneration
        try await rig.drop()
        await rig.controller.update(binding: nil, scene: .background)
        try await rig.reconnect()
        let binding = try rig.currentBinding()
        #expect(binding.connectionGeneration != rootAuthorizedGeneration)
        let cardExists = binding.connectionGeneration == rootAuthorizedGeneration || rig.controller.reconnect.isPending
        #expect(!cardExists) // The reviewer's former foreground-only predicate loses the card.
        if appliedBinding(rig, selected: original) != nil { rootAuthorizedGeneration = binding.connectionGeneration }
        let rootDestinationExists = binding.connectionGeneration == rootAuthorizedGeneration
        let appliedCardExists = rootDestinationExists || rig.controller.reconnect.isPending
        #expect(!rig.controller.reconnect.isPending)
        #expect(appliedCardExists) // Corrected predicate: the applied generation retains the real destination.
        if !appliedCardExists { await rig.controller.destinationLost() } // StationCard.onDisappear
        #expect(rig.controller.isListening, "Successful background restore removes its card and stops capture")
        #expect(rig.capture.startCount == 1)
        let before = try await audioFrames(rig.socket).count
        try await rig.feed()
        try await waitUntil { try await audioFrames(rig.socket).count > before }
        #expect(rig.released == 0 && rig.unexpected.isEmpty)
        await rig.close()
    }

    enum Loss: CaseIterable, Sendable { case targetRemoval, endpointChange, ownerSelection }

    @Test(arguments: Loss.allCases)
    func appliedBackgroundBindingNeverAuthorizesARealDestinationLoss(loss: Loss) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let original = try rig.currentBinding()
        try await rig.drop()
        await rig.controller.update(binding: nil, scene: .background)
        try await rig.reconnect()
        #expect(appliedBinding(rig, selected: original) != nil)
        switch loss {
        case .targetRemoval:
            try await rig.socket.push(.targets([]))
            try await waitUntil { await MainActor.run {
                rig.store.snapshots[rig.endpoint.id]?.targets.isEmpty == true
            } }
        case .endpointChange:
            await rig.store.upsert(try endpoint(rig.endpoint.id, "ws://127.0.0.1:8766"))
        case .ownerSelection: try await rig.select(restoring: false)
        }
        #expect(appliedBinding(rig, selected: original) == nil)
        switch loss {
        case .ownerSelection: await rig.controller.update(binding: try rig.currentBinding(), scene: .background)
        case .targetRemoval, .endpointChange: await rig.controller.destinationLost()
        }
        #expect(!rig.controller.isListening && !rig.controller.isOn)
        #expect(rig.controller.binding == nil && rig.released == 1)
        try await rig.expectNoAdditionalPCM()
        await rig.close()
    }

    private func appliedBinding(_ rig: AmbientReconnectRig, selected: AmbientAudioBinding) -> AmbientAudioBinding? {
        let controller = rig.controller
        guard controller.isListening, controller.reconnect.notice?.outcome == .applied,
              !controller.reconnect.isPending, let binding = controller.reconnect.binding,
              controller.binding == binding, selected.hostID == binding.hostID, selected.targetID == binding.targetID,
              rig.store.ambientBinding(host: binding.hostID, targetID: binding.targetID) == binding else { return nil }
        return binding
    }
}

@MainActor
private extension AmbientReconnectRig {
    func expectNoAdditionalPCM() async throws {
        let before = try await audioFrames(socket).count
        try await feed()
        #expect(try await audioFrames(socket).count == before)
    }
}
