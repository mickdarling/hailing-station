#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct CodexAppServerEventsTests {
    @Test func earlyExactIDsNeedResponseBeforeAnyOutput() throws {
        let binding = try CodexAppServerFixtures.binding(), context = CodexAppServerFixtures.context(binding)
        var events = CodexAppServerEvents(binding: binding, threadID: "thread")
        try events.begin(context)
        #expect(try events.receive(CodexAppServerFixtures.record("turn/started")).isEmpty)
        #expect(try events.receive(CodexAppServerFixtures.record("item/completed",
                                                               item: CodexAppServerFixtures.item())).isEmpty)
        let prefix = try events.bind("turn")
        #expect(prefix.map(\.turn) == [context, context]); #expect(prefix.map(\.sequence) == [0, 1])
        #expect(prefix.map(\.kind) == [.accepted, .text("invented", isFinal: true, visibility: .userVisible)])
        #expect(try events.receive(CodexAppServerFixtures.record("turn/completed", status: "completed"))
            .map(\.kind) == [.finished])
    }
    @Test func wrongEarlyIDInvalidatesWholePrefixRatherThanAttributingByOrder() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding))
        _ = try events.receive(CodexAppServerFixtures.record("turn/started"))
        _ = try events.receive(CodexAppServerFixtures.record("turn/started", turn: "wrong"))
        #expect(throws: CodexAppServerError.invalidProtocol) { try events.bind("turn") }
    }
    @Test func wrongBindingOrActiveSecondTurnCannotWriteASecondProviderTurn() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        let first = CodexAppServerFixtures.context(events.binding)
        try events.begin(first)
        #expect(throws: CodexAppServerError.turnInProgress) { try events.begin(first) }
        _ = try events.bind("turn")
        #expect(throws: CodexAppServerError.turnInProgress) {
            try events.begin(CodexAppServerFixtures.context(events.binding))
        }
        let wrong = try ProviderSessionBinding(hostID: "wrong", providerID: "codex-owned",
                                              targetID: CodexAppServerFixtures.target, sessionID: "wrong")
        #expect(throws: ProviderContractError.wrongContext) { try events.begin(CodexAppServerFixtures.context(wrong)) }
    }
    @Test func duplicatesAndEndedTombstonesCannotDuplicateTextOrCompleteANewerTurn() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding)); _ = try events.bind("turn")
        let acceptance = try CodexAppServerFixtures.record("turn/started")
        #expect(try events.receive(acceptance).count == 1); #expect(try events.receive(acceptance).isEmpty)
        let item = try CodexAppServerFixtures.record("item/completed", item: CodexAppServerFixtures.item())
        #expect(try events.receive(item).count == 1); #expect(try events.receive(item).isEmpty)
        let terminal = try CodexAppServerFixtures.record("turn/completed", status: "completed")
        #expect(try events.receive(terminal).count == 1)
        try events.begin(CodexAppServerFixtures.context(events.binding)); _ = try events.bind("new")
        #expect(try events.receive(item).isEmpty); #expect(try events.receive(terminal).isEmpty)
        #expect(throws: CodexAppServerError.invalidProtocol) { try events.receive(
            CodexAppServerFixtures.record("turn/started", turn: "unknown")) }
    }
    @Test(arguments: ["completed", "interrupted", "failed"]) func terminalStatesStayDistinct(status: String) throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding)); _ = try events.bind("turn")
        _ = try events.receive(CodexAppServerFixtures.record("turn/started"))
        let expected: ProviderEventKind = status == "completed" ? .finished
            : status == "interrupted" ? .interrupted : .failed(.providerFailed)
        #expect(try events.receive(CodexAppServerFixtures.record("turn/completed", status: status)).map(\.kind)
            == [expected])
    }
    @Test(arguments: [0, 1, 2, 3]) func incompleteVisibilityNeverBecomesText(mode: Int) throws {
        let item = CodexAppServerFixtures.item(phase: mode == 0 ? .null : mode == 1 ? .string("commentary")
            : .string("final_answer"), delivery: mode == 2 ? .string("async") : .null,
            questions: mode == 3 ? .array([.object(["title": .string("invented question")])]) : .null)
        let record = try CodexAppServerFixtures.record("item/completed", item: item)
        guard case .item(_, let text, _) = record.kind else { Issue.record("not an item"); return }
        #expect(text == nil)
    }
    @Test func unknownDeliveryAndOversizedVisibleTextFailClosed() throws {
        #expect(throws: CodexAppServerError.invalidProtocol) { try CodexAppServerFixtures.record("item/completed",
            item: CodexAppServerFixtures.item(delivery: .string("invented-unknown"))) }
        #expect(throws: CodexAppServerError.invalidProtocol) { try CodexAppServerFixtures.record("item/completed",
            item: CodexAppServerFixtures.item(text: String(repeating: "x", count: 8_193))) }
        let record = try CodexAppServerFixtures.record("item/completed",
            item: CodexAppServerFixtures.item(text: String(repeating: "x", count: 8_192)))
        guard case .item(_, let text, _) = record.kind else { Issue.record("not an item"); return }
        #expect(try #require(text).utf8.count == 8_192)
    }
    @Test func earlyCountByteAndItemRetentionRefuseRatherThanEvict() throws {
        var events = CodexAppServerEvents(binding: try CodexAppServerFixtures.binding(), threadID: "thread")
        try events.begin(CodexAppServerFixtures.context(events.binding))
        for _ in 0..<16 { _ = try events.receive(CodexAppServerFixtures.record("turn/started")) }
        #expect(throws: CodexAppServerError.capacityExceeded) {
            try events.receive(CodexAppServerFixtures.record("turn/started"))
        }
        var bytes = CodexAppServerEvents(binding: events.binding, threadID: "thread")
        try bytes.begin(CodexAppServerFixtures.context(bytes.binding))
        let large = try CodexAppServerFixtures.record("item/completed",
            item: CodexAppServerFixtures.item(text: String(repeating: "x", count: 8_192)))
        for _ in 0..<3 { _ = try bytes.receive(large) }
        #expect(throws: CodexAppServerError.capacityExceeded) { try bytes.receive(large) }
        _ = try events.bind("turn")
        for index in 0..<256 {
            _ = try events.receive(CodexAppServerFixtures.record("item/completed",
                item: CodexAppServerFixtures.item("item-\(index)")))
        }
        #expect(throws: CodexAppServerError.capacityExceeded) { try events.receive(
            CodexAppServerFixtures.record("item/completed", item: CodexAppServerFixtures.item("new-item"))) }
    }
}
#endif
