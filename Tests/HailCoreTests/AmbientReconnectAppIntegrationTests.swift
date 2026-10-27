import Foundation
import Testing
@testable import HailCore

/// The card's retained-controller/selection/notification model, synthetic only. Native UI and haptics need device QA.
@MainActor
@Suite(.serialized) struct AmbientReconnectAppIntegrationTests {
    @Test(arguments: [AmbientListeningReconnect.Outcome.applied, .blocked, .failed])
    func reconnectTitlesDistinguishSuccessAndPreserveStoppedTitle(outcome: AmbientListeningReconnect.Outcome) {
        let notice = AmbientListeningReconnect.Notice(outcome: outcome, reason: nil)
        #expect(notice.notificationTitle == (outcome == .applied
            ? "Hailing Station reconnected" : "Hailing Station stopped listening"))
        #expect(notice.text.contains(outcome == .applied ? "listening resumed" : "tap to resume"))
    }
    @Test func foregroundSelectionReconciliationReusesBackgroundConfirmationAndDoesNotVetoNextDrop() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        let count = try await rig.socket.sentFrames().count { if case .control(.select) = $0.payload {
            return true
        }; return false }
        try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id, restoring: true)
        #expect(try await rig.socket.sentFrames().count { if case .control(.select) = $0.payload {
            return true
        }; return false } == count)
        #expect(rig.capture.startCount == 1 && rig.controller.isListening)
        try await rig.drop()
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.applied, .applied])
        await rig.close()
    }
    @Test func disappearingCardRetainsControllerAndBackgroundStreamingUntilActualDestinationLoss() async throws {
        let rig = try AmbientReconnectRig()
        let store = rig.store
        rig.controller.onListeningChange = { [weak store] in store?.ambientStreaming = $0 }
        try await rig.start()
        try await rig.drop()
        let retained = try #require(store.ambientController)
        await retained.destinationLost() // The existing card-disappear action, never an owner off.
        #expect(store.ambientStreaming && retained === rig.controller && retained.isOn)
        try await rig.reconnect()
        #expect(store.ambientController === retained && store.ambientStreaming)
        await retained.destinationLost()
        #expect(!store.ambientStreaming && !retained.isOn && rig.unexpected.count == 1)
        await rig.close()
    }
}
