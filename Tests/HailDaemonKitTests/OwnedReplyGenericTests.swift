#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Generic owned replies: validation, target gating and the exact reply argv, with an invented job script.
@Suite struct OwnedReplyGenericTests {
    private static let target = "codex-owned:owned"

    @Test func validRepliesKeepNewlinesAndTabs() throws {
        let reply = try OwnedReply(requestID: UUID(), hostID: "synthetic-host", targetID: Self.target,
                                   text: "Invented answer.\n\tSecond line.")
        #expect(reply.text == "Invented answer.\n\tSecond line.")
    }

    @Test(arguments: ["", "   \n", "bad\0text", "bell\u{7}", "del\u{7f}", "cr\rtext",
                      String(repeating: "a", count: PayloadLimits.maxTextBytes + 1)])
    func unsafeTextIsRefused(text: String) {
        #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
            _ = try OwnedReply(requestID: UUID(), hostID: "synthetic-host", targetID: Self.target, text: text)
        }
    }

    @Test(arguments: ["", "tab\ttarget", String(repeating: "t", count: 257)])
    func unsafeTargetsAreRefused(target: String) {
        #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
            _ = try OwnedReply(requestID: UUID(), hostID: "synthetic-host", targetID: target, text: "invented")
        }
    }

    @Test func aConfiguredTargetPublishesItsOwnTextThroughTheReplyCommand() async throws {
        let fixture = try PublisherFixture(mode: "argv")
        let publisher = try fixture.publisher(targets: [Self.target])
        let id = UUID()
        try await publisher.publish(try OwnedReply(requestID: id, hostID: "synthetic-host", targetID: Self.target,
                                                   text: "Invented final answer."))
        let argv = try String(contentsOf: fixture.record, encoding: .utf8).components(separatedBy: "\u{1f}")
        #expect(Array(argv.prefix(9)) == ["reply", Self.target, "--host", "synthetic-host", "--request",
                                          id.uuidString, "--say", "Invented final answer.", "--socket"])
        try await fixture.shutdown(publisher)
    }

    @Test func anUnconfiguredTargetOrHostIsRefusedBeforeAnyChildStarts() async throws {
        let fixture = try PublisherFixture(mode: "argv")
        let publisher = try fixture.publisher()
        await #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
            try await publisher.publish(try OwnedReply(requestID: UUID(), hostID: "synthetic-host",
                                                       targetID: Self.target, text: "invented"))
        }
        await #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
            try await publisher.publish(try OwnedReply(requestID: UUID(), hostID: "other-host",
                                                       targetID: DiagnosticReplyBridgeAdapter.targetID,
                                                       text: "invented"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
        try await fixture.shutdown(publisher)
    }

    @Test func anEmptyTargetSetIsRefused() throws {
        let fixture = try PublisherFixture()
        #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
            _ = try OwnedReplyPublisher(executable: fixture.executable, socket: fixture.base, outputRoot: fixture.root,
                                        hostID: "synthetic-host", targets: [])
        }
        try FileManager.default.removeItem(at: fixture.base)
    }
}
#endif
