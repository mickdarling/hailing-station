import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #923 PR C: only a correlated heard request changes state; notices and announcements remain independent.
@MainActor
@Suite struct HeardTurnAppTests {
    @Test func matchingRefusalMarksTheHeardEntryAndKeepsTheNoticeAndAnnouncement() async throws {
        let ready = try await readyHeardStore()
        let store = ready.store
        var announced: [String] = []
        store.onRequestRefusal = { announced.append($0) }
        let turn = UUID()
        try await hear(turn, on: ready)
        try await refuse(turn, on: ready)
        let entries = store.conversation.entries
        #expect(entries.map(\.notSent) == [true, false])
        #expect(entries.map(\.notice) == [false, true])
        #expect(entries.map(\.text) == ["synthetic request", "synthetic refusal: Nothing was sent."])
        #expect(entries.allSatisfy { $0.targetID == "tmux:a" })
        #expect(entries.first?.overheard == false && entries.first?.heardTurn == nil)
        #expect(announced == ["synthetic refusal: Nothing was sent."])
        #expect(store.replyFrames.isEmpty && store.snapshots[ready.endpoint.id]?.state == .ready)
        await store.disconnect(ready.endpoint.id)
    }

    @Test(arguments: [false, true])
    func differentOrMissingRefusalTurnLeavesTheEntrySent(missing: Bool) async throws {
        let ready = try await readyHeardStore()
        try await hear(UUID(), on: ready)
        try await refuse(missing ? nil : UUID(), on: ready)
        #expect(ready.store.conversation.entries.map(\.notSent) == [false, false])
        #expect(ready.store.conversation.entries.last?.notice == true)
        await ready.store.disconnect(ready.endpoint.id)
    }

    @Test func identicalWordsInFlightMatchOnlyByUUID() async throws {
        let ready = try await readyHeardStore()
        let first = UUID(), second = UUID()
        try await hear(first, on: ready)
        try await hear(second, on: ready)
        try await refuse(first, on: ready)
        #expect(ready.store.conversation.entries.map(\.notSent) == [true, false, false])
        #expect(ready.store.conversation.entries[1].heardTurn == second)
        await ready.store.disconnect(ready.endpoint.id)
    }

    @Test(arguments: [false, true])
    func deliveredRequestStaysSentIncludingOldHostShape(legacy: Bool) async throws {
        let ready = try await readyHeardStore()
        try await hear(legacy ? nil : UUID(), on: ready)
        let reply = ReplyDescriptor(id: UUID(), hostID: "synthetic-host", targetID: "tmux:a")
        let frame = Frame(timestamp: 2, target: reply.targetID, source: reply.hostID,
                          payload: .text(TextPayload(text: "synthetic reply", isFinal: true, reply: reply)))
        try await ready.socket.push(FrameCoding.encode(frame))
        try await waitUntil { await MainActor.run { ready.store.conversation.entries.count == 2 } }
        #expect(ready.store.conversation.entries.allSatisfy { !$0.notSent && !$0.notice })
        #expect(ready.store.conversation.entries.map(\.speaker) == [.you, .haili])
        await ready.store.disconnect(ready.endpoint.id)
    }

    @Test func oldHostRefusalKeepsTheHeardEntrySentAndAddsItsNotice() async throws {
        let ready = try await readyHeardStore()
        try await hear(nil, on: ready)
        try await refuse(nil, on: ready)
        #expect(ready.store.conversation.entries.map(\.notSent) == [false, false])
        #expect(ready.store.conversation.entries.map(\.notice) == [false, true])
        await ready.store.disconnect(ready.endpoint.id)
    }

    @Test func historyEvictionAlsoEvictsCorrelation() {
        let store = HostConnectionStore()
        let old = UUID(), newest = UUID()
        for index in 0...ConversationLog.limit {
            let turn = index == 0 ? old : index == ConversationLog.limit ? newest : UUID()
            #expect(store.receiveAmbientNotice(HostReplyEvent(endpointID: "synthetic-host", frame: Frame(
                timestamp: 1, source: "host", payload: .control(.ambientHeard(
                    targetID: "tmux:a", text: "synthetic request", turn: turn
                ))
            ))))
        }
        #expect(store.conversation.entries.count == ConversationLog.limit)
        #expect(store.conversation.entries.compactMap(\.heardTurn).count == ConversationLog.limit)
        store.conversation.noteHeardRefused(old, endpointID: "synthetic-host")
        #expect(store.conversation.entries.allSatisfy { !$0.notSent })
        store.conversation.noteHeardRefused(newest, endpointID: "synthetic-host")
        #expect(store.conversation.entries.last?.notSent == true)
    }
}

typealias ReadyHeardStore = HostConnectionStoreAmbientBindingTests.ReadyStore

@MainActor
func readyHeardStore() async throws -> HostConnectionStoreAmbientBindingTests.ReadyStore {
    let helper = HostConnectionStoreAmbientBindingTests()
    let ready = try await helper.readyStore(capabilities: ["ping", "select_target", "receive_replies"])
    try await helper.select("tmux:a", on: ready)
    return ready
}

@MainActor
func hear(_ turn: UUID?, on ready: HostConnectionStoreAmbientBindingTests.ReadyStore) async throws {
    let count = ready.store.conversation.entries.count
    try await ready.socket.push(.ambientHeard(targetID: "tmux:a", text: "synthetic request", turn: turn))
    try await waitUntil { await MainActor.run { ready.store.conversation.entries.count == count + 1 } }
}

@MainActor
func refuse(_ turn: UUID?, on ready: HostConnectionStoreAmbientBindingTests.ReadyStore) async throws {
    let count = ready.store.conversation.entries.count
    try await ready.socket.push(.error(
        code: .voiceRouteRefused, message: "synthetic refusal: Nothing was sent.", turn: turn
    ))
    try await waitUntil { await MainActor.run { ready.store.conversation.entries.count == count + 1 } }
}
