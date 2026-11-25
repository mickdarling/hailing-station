import Foundation
import Testing
@testable import HailCore

@MainActor
struct TranscriptTurnTests {
    @Test func onlyTheCompletedSendShowsItsOriginalDestination() throws {
        let log = ConversationLog()
        let label = ConversationEntry.TransportDestination(hostName: "Studio Mac", targetName: "Workbench")
        let id = log.noteSent("Example", endpointID: "host", targetID: "a")
        func turn() throws -> TranscriptTurn {
            TranscriptTurn(entry: try #require(log.entries.first), sessionName: "Another session")
        }
        #expect(try turn().delivery == .unknown)
        log.recordTransportCompletion("absent", to: label)
        #expect(try turn().delivery == .unknown)
        log.recordTransportCompletion(id, to: label)
        #expect(try turn().delivery == .transportCompleted(label))
        var refused = try #require(log.entries.first)
        refused.pasteState = .refused("Example")
        #expect(TranscriptTurn(entry: refused, sessionName: nil).delivery == .notSent)
    }

    @Test func overheardAndAddressedEntriesKeepTheirAttribution() {
        var guest = ConversationEntry(id: "heard", speaker: .someone, text: "Example",
                                      endpointID: "mac", targetID: "other", date: .now)
        guest.overheard = true
        guest.name = "Guest"
        let heard = TranscriptTurn(entry: guest, sessionName: nil)
        #expect(heard.speaker == "Guest")
        #expect(heard.delivery == .overheard)
        var reply = ConversationEntry(id: "reply", speaker: .haili, text: "Example",
                                      endpointID: "mac", targetID: "other", date: .now)
        reply.source = "Research"
        reply.updatePriority = "normal"
        #expect(TranscriptTurn(entry: reply, sessionName: "Selected").session == "Research · Update")
    }
}
