import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Exercises the shared root/card decisions and their hooks; native SwiftUI and physical haptics remain device QA.
@MainActor
@Suite(.serialized) struct AmbientReconnectAppLifetimeTests {
    @Test func pendingRecoveryKeepsUnavailableCardButCannotResumeFromItsCachedBinding() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let original = try rig.currentBinding()
        try await rig.drop()
        let presentation = rig.appPresentation
        #expect(presentation.card(hostName: nil)?.0 == original)
        #expect(presentation.card(hostName: nil)?.1 == rig.endpoint.name)
        #expect(presentation.resumeBinding == nil)
        #expect(presentation.appliedBinding(hostID: original.hostID, targetID: original.targetID) == nil)
        #expect(presentation.notice == nil && !presentation.offersResume)
        await rig.controller.destinationLost() // Card disappearance during recovery does not stop capture.
        #expect(rig.controller.isListening && rig.controller.reconnect.isPending)
        try await rig.reconnect()
        #expect(rig.appPresentation.card(hostName: rig.endpoint.name)?.0 == rig.controller.binding)
        #expect(rig.appPresentation.resumeBinding == rig.controller.binding)
        await rig.close()
    }

    @Test(arguments: [AmbientListeningReconnect.Outcome.blocked, .failed])
    func completedStopNoticeCannotRetainUnavailableCard(outcome: AmbientListeningReconnect.Outcome) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        rig.controller.reconnect.finish(outcome, reason: .privacy)
        await rig.controller.destinationLost()
        let presentation = AmbientRestorePresentation(controller: rig.controller, confirmedBinding: nil)
        #expect(presentation.notice?.outcome == outcome && presentation.offersResume)
        #expect(presentation.card(hostName: nil) == nil)
        #expect(presentation.resumeBinding == nil)
        #expect(!rig.controller.isListening && rig.controller.binding == nil)
        await rig.close()
    }

    enum Loss: CaseIterable, Sendable { case targetRemoval, destinationChange, cardDisappearance }

    @Test(arguments: Loss.allCases, [false, true])
    func successNoticeNeverRetainsCaptureOrAuthorizesADestination(loss: Loss, background: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        if background { await rig.controller.update(binding: nil, scene: .background) }
        try await rig.reconnect()
        let notice = try #require(rig.appPresentation.notice)
        let binding = try #require(rig.controller.binding)
        #expect(notice.outcome == .applied && !rig.appPresentation.offersResume)
        switch loss {
        case .targetRemoval: try await removeTargetAndReconcileCard(rig, binding: binding)
        case .destinationChange:
            try await rig.select(restoring: false)
            await rig.controller.update(binding: rig.appPresentation.resumeBinding,
                                        scene: background ? .background : .active)
        case .cardDisappearance: await rig.controller.destinationLost()
        }
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.released == 1)
        #expect(rig.controller.binding == nil)
        #expect(rig.appPresentation.notice == notice) // History survives independently of capture.
        let frames = try await rig.socket.sentFrames().count
        try await rig.feed()
        #expect(try await rig.socket.sentFrames().count == frames)
        await rig.close()
    }

    private func removeTargetAndReconcileCard(_ rig: AmbientReconnectRig, binding: AmbientAudioBinding) async throws {
        try await rig.socket.push(.targets([]))
        try await waitUntil { await MainActor.run {
            rig.store.snapshots[rig.endpoint.id]?.targets.isEmpty == true
        } }
        #expect(rig.store.ambientBinding(host: binding.hostID, targetID: binding.targetID) == nil)
        let presentation = rig.appPresentation
        #expect(presentation.card(hostName: nil) == nil,
                "A completed notice retained the unavailable destination's card and cached binding")
        #expect(presentation.resumeBinding == nil,
                "A completed notice authorized resume from its cached binding")
        if presentation.card(hostName: nil) == nil {
            await rig.controller.destinationLost() // The card disappears, while the root still shows its notice.
        }
    }
}
