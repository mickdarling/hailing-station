import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReviewLifetimeTests {
    @Test func retainedSuccessCardMustNotKeepStreamingAfterTargetRemoval() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        let binding = try #require(rig.controller.binding)
        try await rig.socket.push(.targets([]))
        try await waitUntil { await MainActor.run { rig.store.snapshots[rig.endpoint.id]?.targets.isEmpty == true } }
        // Even a retained view must receive a lost binding; a notice is never destination authority.
        #expect(rig.controller.reconnect.notice != nil && !rig.controller.reconnect.isPending)
        let currentBinding = rig.store.ambientBinding(host: binding.hostID, targetID: binding.targetID)
        await rig.controller.update(binding: currentBinding, scene: .active)
        let before = try await rig.socket.sentFrames().count
        try await rig.feed()
        #expect(!rig.controller.isListening, "A success notice must not keep capture alive after target removal")
        let later = try await rig.socket.sentFrames().dropFirst(before)
        #expect(later.allSatisfy { if case .audio = $0.payload { return false }; return true },
                "PCM is still sent to the removed destination")
        await rig.close()
    }
}
