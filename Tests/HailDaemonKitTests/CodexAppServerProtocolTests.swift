#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension CodexAppServerEventsTests {
    @Test func endedTurnCannotPoisonANewerPendingPrefixButConflictsStillFail() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding)); _ = try events.bind("old")
        _ = try events.receive(CodexAppServerFixtures.record("turn/started", turn: "old"))
        let original = CodexAppServerFixtures.item("seen")
        _ = try events.receive(CodexAppServerFixtures.record("item/completed", turn: "old", item: original))
        _ = try events.receive(CodexAppServerFixtures.record("turn/completed", turn: "old", status: "completed"))
        let next = CodexAppServerFixtures.context(events.binding)
        try events.begin(next)
        for record in [try CodexAppServerFixtures.record("turn/started", turn: "old"),
                       try CodexAppServerFixtures.record("item/completed", turn: "old",
                                                        item: CodexAppServerFixtures.item("unseen-late")),
                       try CodexAppServerFixtures.record("item/completed", turn: "old", item: original),
                       try CodexAppServerFixtures.record("turn/completed", turn: "old", status: "completed")] {
            #expect(try events.receive(record).isEmpty)
        }
        #expect(events.bufferedEarlyRecords == 0)
        #expect(throws: CodexAppServerError.invalidProtocol) {
            try events.receive(CodexAppServerFixtures.record("item/completed", turn: "old",
                item: CodexAppServerFixtures.item("seen", text: "invented changed text")))
        }
        #expect(throws: CodexAppServerError.invalidProtocol) {
            try events.receive(CodexAppServerFixtures.record("turn/completed", turn: "old", status: "failed"))
        }
        _ = try events.receive(CodexAppServerFixtures.record("turn/started", turn: "new"))
        _ = try events.receive(CodexAppServerFixtures.record("item/completed", turn: "new", item: original))
        _ = try events.receive(CodexAppServerFixtures.record("turn/completed", turn: "new", status: "completed"))
        let prefix = try events.bind("new")
        #expect(prefix.map(\.turn) == [next, next, next])
        #expect(prefix.map(\.kind) == [
            .accepted, .text("invented", isFinal: true, visibility: .userVisible), .finished
        ])
        #expect(prefix.map(\.sequence) == [3, 4, 5])
    }
    @Test(arguments: ["user", "auto_review", "guardian_subagent", "missing"])
    func effectiveApprovalReviewerMustBeExplicitUser(reviewer: String) async throws {
        let command = CodexAppServerFixtures.command(approvalsReviewer: reviewer == "missing" ? nil : reviewer)
        let transport = try await CodexStdioTransport.withTransport(command: command) { transport in
            if reviewer == "user" {
                let thread = try await CodexAppServerProtocol.start(transport)
                #expect(thread == "synthetic-thread")
            } else {
                await #expect(throws: CodexAppServerError.invalidProtocol) {
                    try await CodexAppServerProtocol.start(transport)
                }
            }
            return transport
        }
        #expect(await transport.isReaped)
    }
    @Test func fullItemTombstonesRefuseNextContextBeforeProviderRequestAdmission() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding)); _ = try events.bind("turn")
        _ = try events.receive(CodexAppServerFixtures.record("turn/started"))
        for number in 0..<256 {
            _ = try events.receive(CodexAppServerFixtures.record("item/completed",
                item: CodexAppServerFixtures.item("item-\(number)")))
        }
        _ = try events.receive(CodexAppServerFixtures.record("turn/completed", status: "completed"))
        #expect(throws: CodexAppServerError.capacityExceeded) {
            try events.begin(CodexAppServerFixtures.context(events.binding))
        }
        #expect(events.bufferedEarlyRecords == 0)
    }
    @Test(arguments: [false, true]) func conflictingItemIdentityIsRejectedEvenAfterTerminal(ended: Bool) throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding)); _ = try events.bind("turn")
        _ = try events.receive(CodexAppServerFixtures.record("turn/started"))
        _ = try events.receive(CodexAppServerFixtures.record("item/completed", item: CodexAppServerFixtures.item()))
        if ended { _ = try events.receive(CodexAppServerFixtures.record("turn/completed", status: "completed")) }
        for item in [CodexAppServerFixtures.item(text: "conflicting invented text"),
                     CodexAppServerFixtures.item(phase: .string("commentary"))] {
            #expect(throws: CodexAppServerError.invalidProtocol) {
                try events.receive(CodexAppServerFixtures.record("item/completed", item: item))
            }
        }
    }
    @Test func contradictoryCompletedErrorCannotBecomeFinished() throws {
        let params: JSONValue = .object(["threadId": .string("thread"), "turn": .object([
            "id": .string("turn"), "status": .string("completed"), "items": .array([]),
            "error": .object(["message": .string("invented provider diagnostic")])
        ])])
        #expect(throws: CodexAppServerError.invalidProtocol) {
            try CodexAppServerRecord(.init(method: "turn/completed", params: params))
        }
    }
    @Test func conflictingTerminalInvalidatesHeldPrefixAndCannotReplaceExistingTerminal() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding))
        _ = try events.receive(CodexAppServerFixtures.record("turn/started"))
        _ = try events.receive(CodexAppServerFixtures.record("turn/completed", status: "completed"))
        _ = try events.receive(CodexAppServerFixtures.record("turn/completed", status: "failed"))
        #expect(throws: CodexAppServerError.invalidProtocol) { try events.bind("turn") }
        #expect(throws: CodexAppServerError.invalidProtocol) {
            try events.receive(CodexAppServerFixtures.record("turn/completed", status: "interrupted"))
        }
    }
    @Test func emptyQuestionsAreOrdinaryWhileHiddenKindsAndDeltasAreSuppressed() throws {
        let record = try CodexAppServerFixtures.record("item/completed",
            item: CodexAppServerFixtures.item(questions: .array([])))
        guard case .item(_, let text, _) = record.kind else { Issue.record("missing item"); return }
        #expect(try #require(text) == "invented")
        let ignored = try CodexAppServerRecord(.init(method: "item/agentMessage/delta", params: .null))
        #expect(ignored == nil)
        let hidden = try CodexAppServerFixtures.record("item/completed",
            item: .object(["id": .string("tool"), "type": .string("reasoning"), "text": .string("invented hidden")]))
        guard case .item(_, let hiddenText, _) = hidden.kind else { Issue.record("missing hidden item"); return }
        #expect(hiddenText == nil)
    }
    @Test func turnAndContextTombstonesRemainBounded() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        for number in 0..<64 {
            let id = "turn-\(number)"
            try events.begin(CodexAppServerFixtures.context(events.binding)); _ = try events.bind(id)
            _ = try events.receive(CodexAppServerFixtures.record("turn/started", turn: id))
            _ = try events.receive(CodexAppServerFixtures.record("turn/completed", turn: id, status: "completed"))
        }
        #expect(throws: CodexAppServerError.capacityExceeded) {
            try events.begin(CodexAppServerFixtures.context(events.binding))
        }
    }
}
#endif
