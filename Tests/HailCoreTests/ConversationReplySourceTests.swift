import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #636 slice 7a: a reply from another session shows in the open thread, labelled with that session's listed name,
/// only when it answers a request the user addressed to it by name from that thread. Any other stays in its own
/// thread (Codex and Jarvis review on #666). Synthetic frames and an injected clock.
@MainActor
@Suite struct ConversationReplySourceTests {
    private static let targets = [
        TargetInfo(id: "tmux:scratch", kind: "tmux", name: "Hailing Scratch", alive: true),
        TargetInfo(id: "tmux:deck", kind: "tmux", name: "Deck", alive: true),
        TargetInfo(id: "tmux:voice", kind: "tmux", name: "Voice Work", alive: true),
        TargetInfo(id: "tmux:claude-hail", kind: "tmux", name: "claude-hail", alive: true),
        TargetInfo(id: "tmux:cafe", kind: "tmux", name: "Café", alive: true)
    ]

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    private func reply(_ text: String, id: UUID = UUID(), from target: String, endpoint: String = "mac")
        -> HostReplyEvent {
        let descriptor = ReplyDescriptor(id: id, hostID: "host", targetID: target)
        let frame = Frame(timestamp: 0, source: "host", payload: .text(TextPayload(text: text, reply: descriptor)))
        return HostReplyEvent(endpointID: endpoint, frame: frame)
    }

    @Test func aReplyToARequestAddressedFromThisThreadShowsHereLabelled() {
        let log = ConversationLog()
        log.noteSent("Deck, add a slide on pricing", endpointID: "mac", targetID: "tmux:scratch",
                     targets: Self.targets, scope: "s1")
        log.noteReply(reply("Added it.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.noteReply(reply("Done here too.", from: "tmux:scratch"), selected: "tmux:scratch", scope: "s1")
        let thread = log.entries(endpointID: "mac", targetID: "tmux:scratch")
        #expect(thread.map(\.text) == ["Deck, add a slide on pricing", "Added it.", "Done here too."])
        #expect(thread.map(\.source) == [nil, "Deck", nil], "the selected session's own reply needs no label")
        #expect(log.entries(endpointID: "mac", targetID: "tmux:deck").map(\.text) == ["Added it."])
        #expect(log.entries(endpointID: "other", targetID: "tmux:scratch").isEmpty)
    }

    /// Unsolicited, late or someone else's replies from another session never pile into the open thread.
    @Test func aReplyNobodyAddressedFromThisThreadStaysInItsOwn() {
        let log = ConversationLog()
        log.noteReply(reply("Unrelated.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.noteSent("Voice Work, run the tests", endpointID: "mac", targetID: "tmux:scratch",
                     targets: Self.targets, scope: "s1")
        log.noteReply(reply("Still unrelated.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.noteSent("Deck, add a slide", endpointID: "other", targetID: "tmux:scratch",
                     targets: Self.targets, scope: "s1")
        log.noteReply(reply("Wrong endpoint.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        #expect(log.entries(endpointID: "mac", targetID: "tmux:scratch").map(\.text) == ["Voice Work, run the tests"])
        #expect(log.entries.filter { $0.speaker == .haili }.allSatisfy { $0.shownIn == nil && $0.source == nil })
    }

    @Test func anAddressExpiresWithTheHostsClaim() {
        let clock = Clock()
        let log = ConversationLog(now: { clock.date })
        log.noteSent("Deck: add a slide", endpointID: "mac", targetID: "tmux:scratch",
                     targets: Self.targets, scope: "s1")
        clock.date += AddressedRequest.addressLifetime - 1
        log.noteReply(reply("In time.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        clock.date += 2
        log.noteReply(reply("Too late.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        let thread = log.entries(endpointID: "mac", targetID: "tmux:scratch").map(\.text)
        #expect(thread == ["Deck: add a slide", "In time."])
    }

    /// The host retires its reply claim on any reselection or reconnect, so an address under another scope, or none,
    /// never places a reply (Codex review on #666).
    @Test func anAddressOnlyHoldsForTheConnectionAndSelectionItWasSentOn() {
        let log = ConversationLog()
        log.noteSent("Deck, add a slide", endpointID: "mac", targetID: "tmux:scratch", targets: Self.targets)
        log.noteReply(reply("No scope.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.noteSent("Deck, add a slide", endpointID: "mac", targetID: "tmux:scratch", targets: Self.targets,
                     scope: "s1")
        log.noteReply(reply("Reselected.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s2")
        log.noteReply(reply("Same scope.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        let thread = log.entries(endpointID: "mac", targetID: "tmux:scratch").filter { $0.speaker == .haili }
        #expect(thread.map(\.text) == ["Same scope."])
    }

    /// One address places one reply (Codex review on #666): a second reply from that session stays in its own thread.
    @Test func anAddressPlacesOnlyItsFirstReply() {
        let log = ConversationLog()
        log.noteSent("Deck, add a slide", endpointID: "mac", targetID: "tmux:scratch", targets: Self.targets,
                     scope: "s1")
        log.noteReply(reply("Added it.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.noteReply(reply("Unrelated update.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        let thread = log.entries(endpointID: "mac", targetID: "tmux:scratch").filter { $0.speaker == .haili }
        #expect(thread.map(\.text) == ["Added it."])
    }

    /// Tap-to-talk records the address before sending (Codex review on #666): a reply that arrives before the send
    /// returns is still placed, and a send that fails takes its address back.
    @Test func anAddressRecordedBeforeTheSendPlacesAFastReplyAndAFailedSendRetractsIt() {
        let log = ConversationLog()
        log.address("Deck, add a slide", endpointID: "mac", targetID: "tmux:scratch", targets: Self.targets,
                    scope: "s1")
        log.noteReply(reply("Fast.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.noteSent("Deck, add a slide", endpointID: "mac", targetID: "tmux:scratch")
        let failed = log.address("Deck, again", endpointID: "mac", targetID: "tmux:scratch", targets: Self.targets,
                                 scope: "s1")
        #expect(failed != nil)
        log.retractAddress(failed)
        log.noteReply(reply("Not for a failed send.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        let placed = log.entries(endpointID: "mac", targetID: "tmux:scratch").filter { $0.speaker == .haili }
        #expect(placed.map(\.text) == ["Fast."] && placed.first?.source == "Deck")
    }

    /// A reply placed by an address whose send then fails goes back to its own thread (Codex review on #666).
    @Test func aFailedSendUndoesThePlacementItsAddressMade() {
        let log = ConversationLog()
        let address = log.address("Deck, add a slide", endpointID: "mac", targetID: "tmux:scratch",
                                  targets: Self.targets, scope: "s1")
        log.noteReply(reply("Older reply.", from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.retractAddress(address)
        #expect(log.entries(endpointID: "mac", targetID: "tmux:scratch").isEmpty)
        #expect(log.entries.first?.source == nil && log.entries.first?.shownIn == nil)
        #expect(log.entries(endpointID: "mac", targetID: "tmux:deck").map(\.text) == ["Older reply."])
    }

    @Test func thePlacementIsFixedAtTheFirstText() {
        let log = ConversationLog()
        let id = UUID()
        log.noteSent("Deck, status?", endpointID: "mac", targetID: "tmux:scratch", targets: Self.targets, scope: "s1")
        log.noteReply(reply("First.", id: id, from: "tmux:deck"), selected: "tmux:scratch", scope: "s1")
        log.noteReply(reply("First, then more.", id: id, from: "tmux:deck"), selected: "tmux:voice", scope: "s1")
        #expect(log.entries.last?.text == "First, then more." && log.entries.last?.shownIn == "tmux:scratch")
    }

    @Test(arguments: [
        ("Deck, add a slide", "tmux:deck"), ("hey deck - status", "tmux:deck"), ("Voice Work: run it", "tmux:voice"),
        ("Okay hailing scratch, hi", "tmux:scratch"), ("Deck", nil), ("Deck is stopped, check it", nil),
        ("Deck-building is next", nil), ("Can Deck, add a slide", nil), ("Sales, how are we?", nil),
        ("claude-hail, status", nil), ("Voice, Work, status", nil), ("Hey, Deck, add a slide", "tmux:deck"),
        ("Café, hi", nil), ("' Deck, hi", nil)
    ])
    func onlyAListedNameAndAMarkAtTheStartAddressASession(_ text: String, _ target: String?) {
        #expect(AddressedRequest.target(addressedIn: text, among: Self.targets)?.id == target)
    }
}
