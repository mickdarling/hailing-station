import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #608 on the device: a paste is checked before sending, rides with a spoken request or alone, only to a host that
/// advertises `pasted_text`, and joins the conversation as its own block. Synthetic text only.
@Suite struct PastedDraftTests {
    @Test func aDraftNeedsVisibleTextWithinTheCap() throws {
        #expect(throws: PastedDraft.Problem.empty) { try PastedDraft(" \n\t ") }
        let over = String(repeating: "p", count: PayloadLimits.maxPastedTextBytes + 1)
        #expect(throws: PastedDraft.Problem.tooLarge(bytes: over.utf8.count, limit: PayloadLimits.maxPastedTextBytes)) {
            try PastedDraft(over)
        }
        #expect(try PastedDraft("note").text == "note")
    }

    @Test func everyProblemHasAPlainMessage() {
        #expect(PastedDraft.Problem.tooLarge(bytes: 40_000, limit: 32_768).message
            == "The pasted text is too large (40 KB; the limit is 32 KB).")
        #expect(!PastedDraft.Problem.empty.message.isEmpty)
        #expect(!PastedDraft.Problem.unsupportedByHost.message.isEmpty)
    }

    @Test func aLongPasteCollapsesToItsFirstLines() throws {
        let short = try PastedDraft("one\ntwo")
        #expect(!short.isLong)
        #expect(short.preview == "one\ntwo")
        let long = try PastedDraft((1...10).map { "line \($0)" }.joined(separator: "\n"))
        #expect(long.isLong)
        #expect(long.lineCount == 10)
        #expect(long.preview == "line 1\nline 2\nline 3\nline 4…")
        let wide = try PastedDraft(String(repeating: "w", count: 400))
        #expect(wide.isLong)
        #expect(wide.preview.count == PastedDraft.collapsedCharacters + 1)
    }

    @MainActor @Test func theConversationKeepsThePasteBesideTheSpokenText() {
        let log = ConversationLog()
        log.noteSent("compare this", pasted: "synthetic note", endpointID: "mac", targetID: "tmux:a")
        log.noteSent("", pasted: "only a paste", endpointID: "mac", targetID: "tmux:a")
        log.noteSent("  ", pasted: nil, endpointID: "mac", targetID: "tmux:a")
        #expect(log.entries.map(\.text) == ["compare this", ""])
        #expect(log.entries.map(\.pasted) == ["synthetic note", "only a paste"])
    }
}

@Suite struct HostConnectionPasteTests {
    private func ready(capabilities: [String]) async throws -> (HostConnection, ScriptedSocket) {
        let mac = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(socket), for: mac.url)
        let connection = HostConnection(endpoint: mac, connector: connector, deviceName: "Test iPad")
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: capabilities, deviceName: "Mac"
        )))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        return (connection, socket)
    }

    @Test func aPasteRidesOnTheFinalTextFrame() async throws {
        let (connection, socket) = try await ready(capabilities: ["send_text", PastedText.capability])
        try await connection.sendFinalText("compare this", pasted: try PastedDraft("synthetic note"), to: "tmux:a")
        try await connection.sendFinalText("", pasted: try PastedDraft("alone"), to: "tmux:a")
        let texts = try await socket.sentFrames().compactMap { frame -> TextPayload? in
            guard case .text(let text) = frame.payload else { return nil }
            return text
        }
        #expect(texts == [
            TextPayload(text: "compare this", pasted: PastedText(text: "synthetic note")),
            TextPayload(text: "", pasted: PastedText(text: "alone"))
        ])
        await connection.disconnect()
    }

    @Test func anOlderHostIsNeverSentAPaste() async throws {
        let (connection, socket) = try await ready(capabilities: ["send_text"])
        let before = try await socket.sentFrames().count
        await #expect(throws: PastedDraft.Problem.unsupportedByHost) {
            try await connection.sendFinalText("compare this", pasted: try PastedDraft("note"), to: "tmux:a")
        }
        #expect(try await socket.sentFrames().count == before)
        // Spoken text alone still goes.
        try await connection.sendFinalText("compare this", to: "tmux:a")
        await connection.disconnect()
    }

    @Test func aPasteThatEscapesPastTheFrameCapIsRefusedBeforeSending() async throws {
        let (connection, socket) = try await ready(capabilities: ["send_text", PastedText.capability])
        let before = try await socket.sentFrames().count
        // Within the 32 KB paste cap, but each control character encodes as six bytes of JSON.
        let controls = try PastedDraft(String(repeating: "\u{01}", count: 20_000))
        await #expect(throws: PastedDraft.Problem.tooManySpecialCharacters) {
            try await connection.sendFinalText("", pasted: controls, to: "tmux:a")
        }
        #expect(try await socket.sentFrames().count == before)
        await connection.disconnect()
    }

    /// #637 review: a Mac's refusal of a paste request ends that request, never the connection. It reaches the reply
    /// observer as an event; any other host error still ends the connection as before.
    @Test func aPasteRefusalKeepsTheConnection() async throws {
        let mac = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        let events = PasteEvents()
        await connector.enqueue(.socket(socket), for: mac.url)
        let connection = HostConnection(endpoint: mac, connector: connector, replyObserver: { await events.append($0) })
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["send_text", PastedText.capability], deviceName: "Mac"
        )))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        try await socket.push(.error(code: .malformed, message: "pastes go only to agent sessions"))
        try await waitUntil { await events.values.count == 1 }
        #expect(await connection.currentSnapshot().state == .ready)
        try await socket.push(.error(code: .notAllowed, message: "target requires confirmation at the Mac"))
        try await waitUntil { await connection.currentSnapshot().state != .ready }
        await connection.disconnect()
    }
}

@MainActor @Suite struct PasteConversationStateTests {
    @Test func aPasteIsPendingUntilARefusalMarksItWithTheReason() throws {
        let log = ConversationLog()
        log.noteSent("compare", pasted: "first", endpointID: "mac", targetID: "tmux:a")
        log.noteSent("again", pasted: "second", endpointID: "mac", targetID: "tmux:a")
        #expect(log.entries.map(\.pasteState) == [.pending, .pending])
        let refused = try #require(log.notePasteRefused("pastes go only to agent sessions", endpointID: "mac"))
        #expect(refused.text == "second")
        #expect(log.entries.map(\.pasteState) == [.pending, .refused("pastes go only to agent sessions")])
        #expect(log.notePasteRefused("x", endpointID: "other") == nil)
    }

    @Test func aReplyFromTheDestinationMarksItsPendingPastesDelivered() throws {
        let log = ConversationLog()
        log.noteSent("compare", pasted: "note", endpointID: "mac", targetID: "tmux:a")
        log.noteSent("other", pasted: "note", endpointID: "mac", targetID: "tmux:b")
        log.noteReply(HostReplyEvent(endpointID: "mac", frame: Frame(timestamp: 1, source: "mac", payload: .text(
            TextPayload(text: "Done.", reply: ReplyDescriptor(id: UUID(), hostID: "mac", targetID: "tmux:a"))
        ))))
        #expect(log.entries.prefix(2).map(\.pasteState) == [.delivered, .pending])
        #expect(log.entries.last?.pasted == nil) // a host reply never carries a paste
    }
}

private actor PasteEvents {
    private(set) var values: [HostReplyEvent] = []
    func append(_ event: HostReplyEvent) { values.append(event) }
}
