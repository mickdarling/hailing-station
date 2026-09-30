import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct CodexStdioFramingTests {
    @Test func fragmentedUnicodeAndCoalescedFrames() throws {
        var framing = try CodexJSONL()
        let bytes = Data("{\"text\":\"invented 🛰\"}\n{\"id\":1,\"result\":null}\n".utf8)
        var frames: [JSONValue] = []
        for byte in bytes { try framing.append(Data([byte])) { value, _ in frames.append(value) } }
        try framing.finish()
        #expect(frames == [.object(["text": .string("invented 🛰")]), .object(["id": .integer(1), "result": .null])])
    }
    @Test(arguments: [#"{"id":1,"id":2,"result":null}"#,
                      #"{"id":1,"\u0069d":2,"result":null}"#,
                      #"{"params":{"key":1,"key":2}}"#, #"{"a":1,}"#, #"[1,]"#, "", "true false"])
    func duplicateKeysAndMalformedJSONAreRejected(source: String) {
        #expect(throws: CodexStdioError.malformedFrame) { try CodexJSONL.decode(Data(source.utf8)) }
    }
    @Test func depthTokensAndInvalidUTF8AreBoundedBeforeDecoding() {
        let deep = String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18)
        let many = "[" + Array(repeating: "0", count: 2_049).joined(separator: ",") + "]"
        for source in [deep, many] {
            #expect(throws: CodexStdioError.malformedFrame) { try CodexJSONL.decode(Data(source.utf8)) }
        }
        #expect(throws: CodexStdioError.malformedFrame) { try CodexJSONL.decode(Data([34, 255, 34])) }
    }
    @Test func noNewlineOverflowAndTruncatedEOFAreExplicit() throws {
        var framing = try CodexJSONL(maxFrameBytes: 4)
        try framing.append(Data("null".utf8)) { _, _ in Issue.record("Unexpected frame") }
        #expect(throws: CodexStdioError.truncatedFrame) { try framing.finish() }
        #expect(throws: CodexStdioError.oversizedFrame) {
            try framing.append(Data([32])) { _, _ in Issue.record("Unexpected frame") }
        }
    }
    @Test func exactLimitAndCRLFAreAccepted() throws {
        var framing = try CodexJSONL(maxFrameBytes: 5)
        var values: [JSONValue] = []
        try framing.append(Data("null\r\n".utf8)) { value, _ in values.append(value) }
        #expect(values == [.null])
    }
    @Test(arguments: [#"{"id":1,"result":null,"error":{}}"#,
                      #"{"id":null,"result":null}"#, #"{"id":1.2,"result":null}"#,
                      #"{"method":"notice","result":null}"#, #"{"id":1,"result":null,"extra":true}"#])
    func ambiguousEnvelopesFailClosed(source: String) throws {
        let value = try CodexJSONL.decode(Data(source.utf8))
        #expect(throws: CodexStdioError.malformedFrame) { try CodexRPCEnvelope(value) }
    }
    @Test func serverRequestsCannotBecomeNotifications() throws {
        let request: JSONValue = .object(["id": .integer(1), "method": .string("invented/approval")])
        #expect(throws: CodexStdioError.serverRequest) { try CodexRPCEnvelope(request) }
    }
}
