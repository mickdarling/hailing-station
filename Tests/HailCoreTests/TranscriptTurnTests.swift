import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
struct TranscriptTurnTests {
    @Test func onlyTheCompletedSendShowsItsOriginalDestination() throws {
        let log = ConversationLog()
        let label = ConversationEntry.TransportDestination(hostName: "Studio Mac", targetName: "Workbench")
        let id = log.noteSent("Example", endpointID: "host", targetID: "a")
        func turn() throws -> TranscriptTurn {
            let first = log.entries.first
            return TranscriptTurn(entry: try #require(first), sessionName: "Another session")
        }
        #expect(try turn().delivery == .unknown)
        log.recordTransportCompletion("absent", to: label)
        #expect(try turn().delivery == .unknown)
        log.recordTransportCompletion(id, to: label)
        #expect(try turn().delivery == .transportCompleted(label))
        let first = log.entries.first
        var refused = try #require(first)
        refused.pasteState = .refused("Example")
        #expect(TranscriptTurn(entry: refused, sessionName: nil).delivery == .notSent)
    }

    @Test(arguments: ConversationEntry.Speaker.allCases)
    func documentShowsTheRecordedSpeaker(speaker: ConversationEntry.Speaker) {
        var entry = ConversationEntry(id: "turn", speaker: speaker, text: "Example",
                                      endpointID: "mac", targetID: "session", date: .now)
        entry.name = "Speaker B"
        let expected = switch speaker {
        case .you: "You"
        case .someone: "Speaker B"
        case .haili: "Haili"
        }
        #expect(TranscriptTurn(entry: entry, sessionName: nil).speaker == expected)
    }

    @Test func unnamedOverheardSpeakerIsUnknown() {
        let log = ConversationLog()
        log.noteOverheard("Example", owner: false, endpointID: "mac", targetID: "session")
        let entry = log.entries.first
        #expect(entry.map { TranscriptTurn(entry: $0, sessionName: nil).speaker } == "Unknown")
    }

    @Test(arguments: [false, true])
    func heardStateSurvivesMissingOrClearedCorrelation(correlated: Bool) throws {
        let store = HostConnectionStore()
        let correlation = correlated ? UUID() : nil
        let frame = Frame(timestamp: 1, source: "host", payload: .control(.ambientHeard(
            targetID: "session", text: "Example", turn: correlation
        )))
        let handled = store.receiveAmbientNotice(HostReplyEvent(endpointID: "mac", frame: frame))
        #expect(handled)
        let reported = store.conversation.entries.first
        let entry = try #require(reported)
        #expect(TranscriptTurn(entry: entry, sessionName: nil).delivery == .heard)
        store.conversation.forgetHeardTurns("mac")
        let retained = store.conversation.entries.first
        let historical = try #require(retained)
        #expect(historical.heardTurn == nil)
        #expect(TranscriptTurn(entry: historical, sessionName: nil).delivery == .heard)
    }

    @Test func dispatchChipsDistinguishEveryDeliveryState() {
        let destination = ConversationEntry.TransportDestination(hostName: "Studio Mac", targetName: "Workbench")
        let cases: [(TranscriptTurn.Delivery, (title: String, reading: String)?)] = [
            (.transportCompleted(destination), ("Sent", "Sent to Studio Mac · Workbench.")),
            (.overheard, ("Heard · not sent", "Heard but not sent.")),
            (.notSent, ("Not sent", "Not sent.")),
            (.heard, ("Heard", "Heard. Send unconfirmed.")),
            (.unknown, ("Unconfirmed", "Send unconfirmed.")),
            (.reply, nil)
        ]
        for (delivery, expected) in cases {
            #expect(delivery.chip?.title == expected?.title)
            #expect(delivery.chip?.accessibilityLabel == expected?.reading)
        }
    }

    @Test func matchedHostRefusalReplacesTheHeardChip() {
        let log = ConversationLog()
        let correlation = UUID()
        let id = log.noteSent("Example", endpointID: "mac", targetID: "session")
        log.recordHeardTurn(correlation, for: id)
        log.noteHeardRefused(correlation, endpointID: "mac")
        let delivery = log.entries.first.map { TranscriptTurn(entry: $0, sessionName: nil).delivery }
        #expect(delivery == .notSent)
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
        let update = TranscriptTurn(entry: reply, sessionName: "Selected")
        #expect(update.delivery == .reply)
        #expect(update.session == "Research · Update")
    }
}
