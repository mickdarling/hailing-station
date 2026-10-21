import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// A host's request refusal (#608, #636) joins the chat as one system line in the selected thread and calls the
/// announcement hook once, for every code in `RequestRefusals.codes`; any other error stays a connection failure.
@MainActor
@Suite struct RequestRefusalNoticeTests {
    @Test func eachRequestRefusalIsOneNoticeAndOneAnnouncement() async throws {
        let ready = try await HostConnectionStoreAmbientBindingTests().readyStore(
            capabilities: ["ping", "select_target", "receive_replies"]
        )
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        try await HostConnectionStoreAmbientBindingTests().select("tmux:a", on: ready)
        var announced: [String] = []
        store.onRequestRefusal = { announced.append($0) }
        let messages = RequestRefusals.codes.map { "synthetic refusal: \($0.rawValue)" }
        for (code, message) in zip(RequestRefusals.codes, messages) {
            try await socket.push(.error(code: code, message: message))
        }
        try await waitUntil { await MainActor.run { announced.count == RequestRefusals.codes.count } }
        let thread = store.conversation.entries(endpointID: endpoint.id, targetID: "tmux:a")
        #expect(thread.map(\.text) == messages && thread.allSatisfy(\.notice))
        #expect(announced == messages)
        #expect(store.snapshots[endpoint.id]?.state == .ready, "a request refusal never ends the connection")
        #expect(store.replyFrames.allSatisfy { if case .control = $0.frame.payload { false } else { true } })
        await store.disconnect(endpoint.id)
    }

    @Test func aRefusalNoticeIsNeverAReplyAndABlankOneIsDropped() {
        let log = ConversationLog()
        log.noteRefusal("  ", endpointID: "mac", targetID: "tmux:a")
        log.noteRefusal("voice route: which session? Nothing was sent", endpointID: "mac", targetID: "tmux:a")
        #expect(log.entries.count == 1 && log.entries.first?.notice == true)
        #expect(log.entries.first?.speaker == .haili && log.entries.first?.id.hasPrefix("notice|") == true)
    }
}
