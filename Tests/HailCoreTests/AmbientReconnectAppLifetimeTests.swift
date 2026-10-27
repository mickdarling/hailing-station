import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Models the root/card lifetime hooks; native SwiftUI layout and physical haptics remain device QA.
@MainActor
@Suite(.serialized) struct AmbientReconnectAppLifetimeTests {
    enum Loss: CaseIterable, Sendable { case targetRemoval, destinationChange, cardDisappearance }

    @Test(arguments: Loss.allCases)
    func successNoticeNeverRetainsCaptureOrAuthorizesADestination(loss: Loss) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        let notice = try #require(rig.controller.reconnect.notice)
        let binding = try #require(rig.controller.binding)
        #expect(notice.outcome == .applied)
        switch loss {
        case .targetRemoval:
            try await rig.socket.push(.targets([]))
            try await waitUntil { await MainActor.run {
                rig.store.snapshots[rig.endpoint.id]?.targets.isEmpty == true
            } }
            #expect(rig.store.ambientBinding(host: binding.hostID, targetID: binding.targetID) == nil)
            await rig.controller.destinationLost() // The card disappears, while the root still shows its notice.
        case .destinationChange:
            try await rig.select(restoring: false)
            await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        case .cardDisappearance:
            await rig.controller.destinationLost()
        }
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.released == 1)
        #expect(rig.controller.binding == nil)
        #expect(rig.controller.reconnect.notice == notice) // History survives independently of capture.
        let frames = try await rig.socket.sentFrames().count
        try await rig.feed()
        #expect(try await rig.socket.sentFrames().count == frames)
        await rig.close()
    }
}
