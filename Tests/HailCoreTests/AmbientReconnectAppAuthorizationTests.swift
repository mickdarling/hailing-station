import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Exercises the root's shared applied-binding predicate and destination fallback, not native SwiftUI.
@MainActor
@Suite(.serialized) struct AmbientReconnectAppAuthorizationTests {
    @Test func backgroundRestoreMustKeepListeningAfterPendingCardDisappears() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let original = try rig.currentBinding()
        try await rig.drop()
        await rig.controller.update(binding: nil, scene: .background)
        try await rig.reconnect()
        let binding = try rig.currentBinding()
        #expect(binding.connectionGeneration != original.connectionGeneration)
        let generation = rig.appPresentation.authorizedGeneration(
            hostID: original.hostID, targetID: original.targetID,
            foregroundAuthorized: false, generation: original.connectionGeneration)
        #expect(generation == binding.connectionGeneration,
                "Applied background restore must replace the stale foreground authorization generation")
        #expect(rig.appPresentation.authorizedGeneration(
            hostID: original.hostID, targetID: original.targetID,
            foregroundAuthorized: true, generation: original.connectionGeneration) == binding.connectionGeneration)
        let destinationExists = generation == binding.connectionGeneration
        let presentation = AmbientRestorePresentation(controller: rig.controller,
            confirmedBinding: destinationExists ? binding : nil)
        let card = presentation.card(hostName: destinationExists ? rig.endpoint.name : nil)
        #expect(!rig.controller.reconnect.isPending)
        #expect(card?.0 == binding, "Applied restore lost the destination fallback and removed its card")
        if card == nil { await rig.controller.destinationLost() } // StationCard.onDisappear
        #expect(rig.controller.isListening, "Successful background restore removes its card and stops capture")
        #expect(rig.capture.startCount == 1)
        let before = try await audioFrames(rig.socket).count
        try await rig.feed()
        if rig.controller.isListening { try await waitUntil { try await audioFrames(rig.socket).count > before } }
        #expect(rig.released == 0 && rig.unexpected.isEmpty)
        await rig.close()
    }

    @Test func staleConfirmedGenerationAndOtherSelectionsCannotAuthorizeAppliedRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let original = try rig.currentBinding()
        #expect(rig.appPresentation.appliedBinding(hostID: original.hostID, targetID: original.targetID) == nil)
        try await rig.drop()
        try await rig.reconnect()
        let stale = AmbientRestorePresentation(controller: rig.controller, confirmedBinding: original)
        #expect(stale.appliedBinding(hostID: original.hostID, targetID: original.targetID) == nil,
                "An applied notice authorized a stale confirmed generation")
        #expect(rig.appPresentation.appliedBinding(hostID: "other", targetID: original.targetID) == nil)
        #expect(rig.appPresentation.appliedBinding(hostID: original.hostID, targetID: "other") == nil)
        await rig.close()
        #expect(rig.appPresentation.appliedBinding(hostID: original.hostID, targetID: original.targetID) == nil)
    }

    enum Loss: CaseIterable, Sendable { case targetRemoval, endpointRemoval, ownerSelection }

    @Test(arguments: Loss.allCases)
    func appliedBackgroundBindingNeverAuthorizesARealDestinationLoss(loss: Loss) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let original = try rig.currentBinding()
        try await rig.drop()
        await rig.controller.update(binding: nil, scene: .background)
        try await rig.reconnect()
        #expect(rig.appPresentation.appliedBinding(hostID: original.hostID, targetID: original.targetID) != nil)
        switch loss {
        case .targetRemoval:
            try await rig.socket.push(.targets([]))
            try await waitUntil { await MainActor.run {
                rig.store.snapshots[rig.endpoint.id]?.targets.isEmpty == true
            } }
        case .endpointRemoval:
            await rig.store.remove(rig.endpoint.id)
        case .ownerSelection: try await rig.select(restoring: false)
        }
        #expect(rig.appPresentation.appliedBinding(hostID: original.hostID, targetID: original.targetID) == nil)
        switch loss {
        case .ownerSelection: await rig.controller.update(binding: try rig.currentBinding(), scene: .background)
        case .targetRemoval, .endpointRemoval: await rig.controller.destinationLost()
        }
        #expect(!rig.controller.isListening && !rig.controller.isOn)
        #expect(rig.controller.binding == nil && rig.released == 1)
        try await rig.expectNoAdditionalPCM()
        await rig.close()
    }
}

@MainActor
extension AmbientReconnectRig {
    var appPresentation: AmbientRestorePresentation {
        AmbientRestorePresentation(controller: controller,
            confirmedBinding: store.ambientBinding(host: endpoint.id, targetID: target.id))
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
