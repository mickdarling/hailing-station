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

/// #637 review: a refused paste is shown, not lost. `paste_refused` marks the pending pasted turn refused with the
/// Mac's reason and publishes the paste so the station can give it back; any other code is not a paste refusal.
@MainActor @Suite struct PasteRefusalStoreTests {
    private func refusal(_ code: ErrorCode) -> HostReplyEvent {
        HostReplyEvent(endpointID: "mac", frame: Frame(timestamp: 1, source: "haild", payload: .control(.error(
            code: code, message: "pastes go only to agent sessions"
        ))))
    }

    @Test func aPasteRefusalMarksTheTurnAndOffersThePasteBack() {
        let store = HostConnectionStore()
        store.conversation.noteSent("look", pasted: "synthetic notes", endpointID: "mac", targetID: "tmux:a")
        #expect(!store.receiveAmbientNotice(refusal(.notAllowed)))
        #expect(store.conversation.entries.last?.pasteState == .pending)
        var announced: [String] = []
        store.onRequestRefusal = { announced.append($0) }
        #expect(store.receiveAmbientNotice(refusal(.pasteRefused)))
        let pasted = store.conversation.entries.first { $0.pasted != nil }
        #expect(pasted?.pasteState == .refused("pastes go only to agent sessions"))
        #expect(store.lastPasteRefusal?.pasted == "synthetic notes")
        #expect(store.lastPasteRefusal?.message == "pastes go only to agent sessions")
        // The one conversation line and the one announcement are the shared request refusal's (#692), not a second.
        #expect(store.conversation.entries.filter(\.notice).map(\.text) == ["pastes go only to agent sessions"])
        #expect(announced == ["pastes go only to agent sessions"])
    }
}
