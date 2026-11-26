import Foundation
import Testing
@testable import HailCore

@MainActor
extension TalkRecordingDestinationTests {
    @Test func removalDuringRecordingReportsRefusalOutsideTheUnmountedCard() async throws {
        let host = try await TalkDestinationStoreFixture.make()
        let rig = RecordingFixture()
        let shown = ConversationDestinationID(endpointID: host.host.id, targetID: "a")
        var notices: [TalkSendRefusal] = []
        try await host.select(shown.targetID)
        rig.card.route = StationTalkRoute(store: host.store, selected: { shown }, reportRemoval: { notices.append($0) })
        await rig.record(on: shown)
        _ = try #require(rig.card.recordingDestination)
        await host.store.remove(host.host.id)
        await rig.card.finish(force: true)
        #expect(rig.deliveries.isEmpty && rig.capture.stopCount == 1 && rig.card.talkSession.owner == nil)
        #expect(try await host.socket.transcripts().isEmpty)
        #expect(notices == [.destinationChanged] && rig.card.talkStatus == .notSent(.destinationChanged))
        #expect(rig.card.status == "Not sent: destination changed" && rig.card.finalText == rig.text)
    }

    @Test func reconnectingTheSameMacAndTargetDoesNotReviveItsRecording() async {
        let rig = RecordingFixture()
        await rig.record(on: rig.macA)
        rig.card.connectionGeneration = UUID()
        await rig.card.finish()
        #expect(rig.deliveries.isEmpty && rig.card.status == "Not sent: destination changed")
    }

    @Test(arguments: [false, true])
    func finishChecksTheAdmittedTargetName(renamed: Bool) async throws {
        let host = try await TalkDestinationStoreFixture.make()
        let rig = RecordingFixture()
        let shown = ConversationDestinationID(endpointID: host.host.id, targetID: "a")
        try await host.select(shown.targetID)
        rig.card.route = StationTalkRoute(store: host.store, selected: { shown }, reportRemoval: { _ in })
        await rig.record(on: shown)
        let admitted = try #require(rig.card.recordingDestination)
        try await host.publishTarget("a", named: renamed ? "Renamed" : "Fixture")
        if renamed {
            #expect(throws: TalkSendRefusal.destinationChanged) { try host.store.connection(for: admitted) }
        }
        await rig.card.finish()
        #expect(try await host.socket.transcripts().map(\.text) == (renamed ? [] : [rig.text]))
        if renamed { #expect(rig.card.status == "Not sent: destination changed") }
        await host.store.disconnect(host.host.id)
    }

    @Test(arguments: [false, true], [false, true])
    func inactiveSceneReportsOnlyAChangedSelection(switched: Bool, clearShown: Bool) async throws {
        let host = try await TalkDestinationStoreFixture.make()
        let rig = RecordingFixture()
        let shown = ConversationDestinationID(endpointID: host.host.id, targetID: "a")
        var notices: [TalkSendRefusal] = []
        try await host.select("a")
        rig.card.route = StationTalkRoute(store: host.store, selected: { [weak card = rig.card] in
            card?.scenePhase == .active ? shown : nil
        }, reportRemoval: { notices.append($0) })
        await rig.record(on: shown)
        _ = try #require(rig.card.recordingDestination)
        if switched { try await host.select("b") }
        rig.card.scenePhase = .background
        if clearShown { (rig.card.destinationID, rig.card.destinationGeneration) = (nil, UUID()) }
        await rig.card.talkSession.cleanUpScene {}
        #expect(rig.card.talkStatus == (switched ? .notSent(.destinationChanged) : .ready))
        #expect(notices == (switched ? [.destinationChanged] : []))
        #expect(try await host.socket.transcripts().isEmpty)
        #expect(rig.deliveries.isEmpty && rig.capture.stopCount == 1 && rig.card.talkSession.owner == nil)
        await host.store.disconnect(host.host.id)
    }
}
