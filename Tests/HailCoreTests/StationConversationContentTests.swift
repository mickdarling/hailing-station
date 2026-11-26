import HailProtocol
import SwiftUI
import Testing
@testable import HailCore

@MainActor
struct StationConversationContentTests {
    @Test func disconnectShowsOnlyTheBaseReplyWhileTheThreadAndPasteAreStillRetained() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        let log = rig.store.conversation
        let host = rig.endpoint.id, target = rig.target.id
        log.noteSent("Synthetic request", pasted: "Synthetic paste", endpointID: host, targetID: target)
        for text in ["Earlier reply", "Displayed reply"] {
            let reply = ReplyDescriptor(id: UUID(), hostID: host, targetID: target)
            let event = HostReplyEvent(endpointID: host, frame: Frame(timestamp: 1, target: target, source: host,
                payload: .text(TextPayload(text: text, isFinal: true, reply: reply))))
            log.noteReply(event)
            root.playback.ingest(event)
        }
        guard case .history(let document) = root.stationDocument else {
            Issue.record("Expected the confirmed thread")
            return
        }
        let confirmed = document.allEntries
        #expect(confirmed.map(\.text) == ["Synthetic request", "Earlier reply", "Displayed reply"])
        #expect(confirmed.compactMap(\.pasted) == ["Synthetic paste"])

        await rig.store.disconnect(host)
        try await waitUntil { await MainActor.run { root.destination == nil } }
        #expect(log.entries(endpointID: host, targetID: target, addressed: true) == confirmed)
        guard case .reply(let card) = root.stationDocument else {
            Issue.record("Expected only the displayed playback card after disconnect")
            return
        }
        let displayed = try #require(root.playback.presentationForDisplay)
        #expect(displayed.transcript == "Displayed reply")
        #expect(card.reply == displayed)
        #expect(card.playback === root.playback)
        await rig.close()
    }

    @Test func retainedDocumentReleasesRootAndPlayback() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        weak var releasedRoot: RootView?
        weak var releasedPlayback: ReplyPlaybackController?
        let document: ConversationDocument
        do {
            let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
            releasedRoot = root
            releasedPlayback = root.playback
            guard case .history(let history) = root.stationDocument else {
                Issue.record("Expected a document for the confirmed thread")
                return
            }
            document = history
        }
        withExtendedLifetime(document) {
            #expect(releasedRoot == nil)
            #expect(releasedPlayback == nil)
        }
        await rig.close()
    }
}

// Compile the shipped root adapter against the existing destination harness. Only the document drawing
// surface and platform clipboard are inert. Thread selection, history filtering and the reply card are real.
struct ConversationDocument: View {
    let allEntries: [ConversationEntry]
    let hostName: String?
    let sessions: [String: String]
    let copy: (String) -> Void

    var body: some View { EmptyView() }
}

extension RootView {
    var settingsShowOverheard: Bool { false }
    var settingsWhoseOverheard: String { "owner" }
}

extension StationPlatform {
    static func copy(_ text: String) {}
}
