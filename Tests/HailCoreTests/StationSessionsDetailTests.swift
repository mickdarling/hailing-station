import HailProtocol
import Testing
@testable import HailCore

@MainActor
struct StationSessionsDetailTests {
    @Test func previewUsesOnlyMessagesForThisHostAndTarget() throws {
        let target = TargetInfo(id: "workbench", kind: "tmux", name: "Workbench", alive: true)
        let option = Destination(endpoint: try endpoint("studio"), target: target)
        let log = ConversationLog()
        log.noteSent("Other host", endpointID: "annex", targetID: target.id)
        log.noteSent("Other session", endpointID: option.hostID, targetID: "other")
        log.noteOverheard("Unsent remark", owner: true, endpointID: option.hostID, targetID: target.id)
        #expect(option.latestMessage(in: log) == nil)

        log.noteSent("First", endpointID: option.hostID, targetID: target.id)
        let latestID = log.noteSent("Latest", endpointID: option.hostID, targetID: target.id)
        log.noteOverheard("Later remark", owner: false, endpointID: option.hostID, targetID: target.id)
        let latest = option.latestMessage(in: log)
        let message = try #require(latest)
        #expect(message.id == latestID && message.text == "Latest")
    }

    @Test func listeningActivityBelongsOnlyToTheBoundDestination() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        #expect(root.confirmedListeningActivity == .streaming)
        root.selectedHostID = "annex"
        #expect(root.confirmedListeningActivity == nil)
        root.selectedHostID = rig.endpoint.id
        root.selectedTargetID = "other"
        #expect(root.confirmedListeningActivity == nil)
        await rig.close()
    }
}
