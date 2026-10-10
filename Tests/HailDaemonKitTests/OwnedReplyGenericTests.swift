#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Generic owned replies: validation, target gating and the exact reply argv, with an invented job script.
@Suite struct OwnedReplyGenericTests {
    private static let target = "codex-owned:owned"

    @Test func emojiSequencesThatInboundSanitizingAllowsAreKept() throws {
        let text = "Done \u{1F469}\u{200D}\u{1F4BB} \u{2764}\u{FE0F}"
        let reply = try OwnedReply(requestID: UUID(), hostID: "synthetic-host", targetID: Self.target, text: text)
        #expect(reply.text == text)
    }

    @Test func validRepliesKeepNewlinesAndTabs() throws {
        let reply = try OwnedReply(requestID: UUID(), hostID: "synthetic-host", targetID: Self.target,
                                   text: "Invented answer.\n\tSecond line.")
        #expect(reply.text == "Invented answer.\n\tSecond line.")
    }

    @Test(arguments: ["", "   \n", "bad\0text", "bell\u{7}", "del\u{7f}", "cr\rtext", "csi\u{9b}text",
                      "bidi\u{202e}text", "zero\u{200b}width", "isolate\u{2066}text", "a\u{FE01}\u{E0100}",
                      "a\u{034F}b", "a\u{3164}b", "a\u{2800}b", "a\u{FFFE}b",
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        try await fixture.shutdown(publisher)
    }

    @Test func anEmptyTargetSetIsRefused() throws {
        let fixture = try PublisherFixture()
        #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
            _ = try OwnedReplyPublisher(executable: fixture.executable, socket: fixture.base, outputRoot: fixture.root,
                                        hostID: "synthetic-host", targets: [])
        }
        #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
            _ = try OwnedReplyPublisher(executable: fixture.executable, socket: fixture.base, outputRoot: fixture.root,
                                        hostID: "synthetic-host", targets: ["codex-owned:owned", "bad\u{7}"])
        }
        for deadline in [Duration.zero, .seconds(601)] {
            #expect(throws: OwnedReplyPublisherError.invalidConfiguration) {
                _ = try OwnedReplyPublisher(executable: fixture.executable, socket: fixture.base,
                                            outputRoot: fixture.root, hostID: "synthetic-host",
                                            targets: ["codex-owned:owned"], deadline: deadline)
            }
        }
        _ = try OwnedReplyPublisher(executable: fixture.executable, socket: fixture.base, outputRoot: fixture.root,
                                    hostID: "synthetic-host", targets: ["codex-owned:owned"], deadline: .seconds(300))
        try FileManager.default.removeItem(at: fixture.base)
    }
}
#endif
