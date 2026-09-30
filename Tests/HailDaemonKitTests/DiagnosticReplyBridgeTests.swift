import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct DiagnosticReplyBridgeTests {
    @Test func strictEnvelopeRoundTripNeverIncludesRoutingInGeneratedText() throws {
        let id = UUID()
        let text = "synthetic \"quoted\" 日本語"
        let encoded = try DiagnosticBridgeEnvelope.encode(requestID: id, text: text)
        let decoded = try DiagnosticBridgeEnvelope.decode(encoded)
        #expect(decoded.requestID == id)
        #expect(decoded.text == text)
        let reply = DiagnosticBridgeReply(requestID: id, hostID: "mac-test", targetID: "test", sequence: 7)
        #expect(reply.text == "Hailing Station diagnostic reply 7. Over to you.")
        #expect(!reply.text.contains(id.uuidString))
        #expect(!reply.text.contains(text))
    }

    @Test(arguments: ["true", "null", "\"1\"", "1.0", "1e0", "2", "[]", "{}"])
    func rejectsNonliteralVersion(version: String) throws {
        let line = "{\"version\":\(version),\"request\":\"\(UUID())\",\"text\":\"synthetic\"}\n"
        #expect(throws: DiagnosticBridgeError.invalidEnvelope) { try DiagnosticBridgeEnvelope.decode(Data(line.utf8)) }
    }

    @Test(arguments: [
        "{}\n", "[]\n", "null\n", "not-json\n", "{\"version\":1,\"request\":1,\"text\":\"x\"}\n",
        "{\"version\":1,\"request\":null,\"text\":\"x\"}\n"
    ])
    func rejectsMalformedEnvelopes(line: String) throws {
        #expect(throws: DiagnosticBridgeError.invalidEnvelope) { try DiagnosticBridgeEnvelope.decode(Data(line.utf8)) }
    }

    @Test func rejectsDuplicateUnknownWrongTextTypesAndLineFraming() throws {
        let fields = "\"version\":1,\"request\":\"\(UUID())\",\"text\":\"synthetic\""
        let lines = ["{\(fields),\"version\":1}\n", "{\(fields),\"extra\":1}\n", "{\(fields)}",
                     "{\(fields)}\n{\(fields)}\n", "{\n\(fields)}\n", "{\(fields)}\r\n"]
        for line in lines {
            #expect(throws: DiagnosticBridgeError.invalidEnvelope) {
                try DiagnosticBridgeEnvelope.decode(Data(line.utf8))
            }
        }
        for value in ["null", "true", "42", "[]", "{}", "\"\"", "\"   \"", "\"two\\nlines\""] {
            let line = "{\"version\":1,\"request\":\"\(UUID())\",\"text\":\(value)}\n"
            #expect(throws: DiagnosticBridgeError.invalidEnvelope) {
                try DiagnosticBridgeEnvelope.decode(Data(line.utf8))
            }
        }
    }

    @Test func refusesOversizedAndInvalidUnicodeEnvelope() throws {
        #expect(throws: DiagnosticBridgeError.invalidEnvelope) {
            try DiagnosticBridgeEnvelope.encode(requestID: UUID(), text: String(repeating: "x", count: 8_193))
        }
        var bytes = Data(repeating: 32, count: PayloadLimits.defaultMaxFrameBytes + 1)
        bytes.append(10)
        #expect(throws: DiagnosticBridgeError.invalidEnvelope) { try DiagnosticBridgeEnvelope.decode(bytes) }
        let line = "{\"version\":1,\"request\":\"\(UUID())\",\"text\":\"\\uD800\"}\n"
        #expect(throws: DiagnosticBridgeError.invalidEnvelope) { try DiagnosticBridgeEnvelope.decode(Data(line.utf8)) }
    }

    @Test func acknowledgesBeforeOutputAndRetainsInterleavedRequestsOutsideText() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let bridge = try diagnosticBridge(publisher)
        let first = try diagnosticContext()
        let second = try diagnosticContext()
        try await bridge.deliver("same synthetic input", to: "roundtrip",
                                 binding: diagnosticUtilityBinding, context: first)
        try await bridge.deliver("same synthetic input", to: "roundtrip",
                                 binding: diagnosticUtilityBinding, context: second)
        await publisher.waitForCount(2)
        let replies = await publisher.replies.sorted { $0.sequence < $1.sequence }
        #expect(replies.map(\.requestID) == [first.id, second.id])
        #expect(replies.map(\.sequence) == [1, 2])
        #expect(await bridge.diagnostics().active == 2)
        await publisher.complete(second.id)
        await publisher.complete(first.id)
        try await diagnosticWait { await bridge.diagnostics().completed == 2 }
        await #expect(throws: DiagnosticBridgeError.duplicateRequest) {
            try await bridge.deliver("synthetic retry", to: "roundtrip",
                                     binding: diagnosticUtilityBinding, context: first)
        }
        await bridge.stop()
    }

    @Test func capacityAndConcurrencyAreBoundedAndStopIsPermanent() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let bridge = try diagnosticBridge(publisher)
        for _ in 0..<16 {
            try await bridge.deliver("synthetic", to: "roundtrip", binding: diagnosticUtilityBinding,
                                     context: diagnosticContext())
        }
        await publisher.waitForCount(4)
        #expect(await bridge.diagnostics().active == 4)
        #expect(await bridge.diagnostics().queued == 12)
        await #expect(throws: DiagnosticBridgeError.capacityExceeded) {
            try await bridge.deliver("synthetic", to: "roundtrip", binding: diagnosticUtilityBinding,
                                     context: diagnosticContext())
        }
        await bridge.stop()
        #expect(await bridge.diagnostics().queued == 0)
        #expect(await bridge.diagnostics().cancelled == 12)
        // The synthetic callback deliberately ignores cancellation until explicitly released.
        #expect(await bridge.diagnostics().active == 4)
        for reply in await publisher.replies { await publisher.complete(reply.requestID) }
        try await diagnosticWait { await bridge.diagnostics().active == 0 }
        #expect(await bridge.diagnostics().cancelled == 16)
        #expect(await bridge.diagnostics().completed == 0)
        #expect(await publisher.replies.count == 4)
        await #expect(throws: DiagnosticBridgeError.stopped) {
            try await bridge.deliver("synthetic", to: "roundtrip", binding: diagnosticUtilityBinding,
                                     context: diagnosticContext())
        }
    }

    @Test func publisherFailureIsVisibleWithoutRawErrorOrSuccessfulAudio() async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let bridge = try diagnosticBridge(publisher)
        let context = try diagnosticContext()
        try await bridge.deliver("private synthetic input", to: "roundtrip",
                                 binding: diagnosticUtilityBinding, context: context)
        await publisher.waitForCount(1)
        await publisher.complete(context.id, failing: true)
        try await diagnosticWait { await bridge.diagnostics().failed == 1 }
        #expect(await bridge.diagnostics().lastFailure == .publisherFailed)
        #expect(await bridge.diagnostics().completed == 0)
        await bridge.stop()
    }
}
