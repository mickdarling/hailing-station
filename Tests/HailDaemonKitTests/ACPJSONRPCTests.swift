import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct ACPJSONRPCTests {
    @Test func eachMessageClassRoundTripsAsOneLFTerminatedLine() throws {
        var rpc = ACPJSONRPC()
        let params: JSONValue = .object(["text": .string("synthetic\n🛰")])
        let lines = [try rpc.request(method: "initialize", params: params),
                     try ACPJSONRPC.notification(method: "session/update", params: params),
                     try ACPJSONRPC.result(id: 7, value: .array([.null, .bool(true)])),
                     try ACPJSONRPC.error(id: 8, code: -32601)]
        let expected: [ACPJSONRPCMessage] = [
            .agentRequest(ACPAgentRequest(id: 1, method: "initialize", params: params)),
            .notification(method: "session/update", params: params),
            .result(id: 7, value: .array([.null, .bool(true)])),
            .error(id: 8, code: -32601, messageBytes: 16)
        ]
        for (line, message) in zip(lines, expected) {
            #expect(line.last == 10)
            #expect(line.filter { $0 == 10 }.count == 1)
            #expect(try ACPJSONRPC.decode(line) == message)
            #expect(try ACPJSONRPC.decode(Data(line.dropLast())) == message)
        }
        #expect(try ACPJSONRPC.decode(ACPJSONRPC.result(id: 0, value: .null)) == .result(id: 0, value: .null))
    }

    @Test func integerIDsIncreaseAndFailedEncodingDoesNotSpendOne() throws {
        var rpc = ACPJSONRPC()
        #expect(throws: ACPJSONRPCError.malformedFrame) { try rpc.request(method: "bad", params: .null) }
        for id in Int64(1)...8 {
            #expect(try ACPJSONRPC.decode(rpc.request(method: "initialize")) ==
                .agentRequest(ACPAgentRequest(id: id, method: "initialize", params: .object([:]))))
        }
    }

    @Test func oversizeDepthTokenAndDuplicateKeyBoundsAreReused() throws {
        #expect(throws: ACPJSONRPCError.oversizedFrame) { try ACPJSONRPC.decode(Data(repeating: 32, count: 65_537)) }
        let deep = String(repeating: "[", count: 16) + "0" + String(repeating: "]", count: 16)
        let many = "[" + Array(repeating: "0", count: 2_049).joined(separator: ",") + "]"
        for result in [deep, many, #"{"key":1,"key":2}"#, #"{"id":1,"\u0069d":2}"#] {
            let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}"
            #expect(throws: ACPJSONRPCError.malformedFrame) { try ACPJSONRPC.decode(Data(line.utf8)) }
        }
        let prefix = #"{"jsonrpc":"2.0","id":1,"result":""#
        let suffix = #""}"#
        let exact = prefix + String(repeating: "x", count: 65_536 - prefix.utf8.count - suffix.utf8.count) + suffix
        _ = try ACPJSONRPC.decode(Data((exact + "\n").utf8))
        #expect(throws: ACPJSONRPCError.oversizedFrame) { try ACPJSONRPC.decode(Data((exact + " \n").utf8)) }
        #expect(throws: ACPJSONRPCError.oversizedFrame) {
            try ACPJSONRPC.result(id: 1, value: .string(String(repeating: "\u{1}", count: 12_000)))
        }
    }

    @Test(arguments: ["fs/read_text_file", "fs/write_text_file", "terminal/create", "unknown/synthetic"])
    func everyAgentMethodGetsMethodNotFound(method: String) throws {
        var rpc = ACPJSONRPC()
        let decoded = try ACPJSONRPC.decode(rpc.request(method: method, params: .object(["text": .string("private")])))
        guard case .agentRequest(let request) = decoded else { Issue.record("Expected agent request"); return }
        let refusal = try ACPJSONRPC.refusal(for: request)
        #expect(try ACPJSONRPC.decode(refusal) == .error(id: 1, code: -32601, messageBytes: 16))
        let text = try #require(String(data: refusal, encoding: .utf8))
        #expect(!text.contains(method) && !text.contains("private"))
    }

    @Test func agentErrorMessagesAndDataAreDiscarded() throws {
        let line = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"synthetic private 🛰","data":{"secret":""#
            + #"synthetic-data"}}}"#
        let decoded = try ACPJSONRPC.decode(Data(line.utf8))
        #expect(decoded == .error(id: 3, code: -32000, messageBytes: "synthetic private 🛰".utf8.count))
        let diagnostic = String(describing: decoded)
        #expect(!diagnostic.contains("synthetic") && !diagnostic.contains("secret"))
        let malformed = line.replacingOccurrences(of: "-32000", with: "\"synthetic-code\"")
        do {
            _ = try ACPJSONRPC.decode(Data(malformed.utf8))
            Issue.record("Expected malformed error")
        } catch {
            #expect(error as? ACPJSONRPCError == .malformedFrame)
            #expect(!String(describing: error).contains("synthetic"))
        }
    }

    @Test(arguments: [#"{"id":1,"result":null}"#, #"{"jsonrpc":"1.0","id":1,"result":null}"#,
                      #"{"jsonrpc":"2.0","id":1,"result":null,"error":{}}"#,
                      #"{"jsonrpc":"2.0","id":null,"result":null}"#,
                      #"{"jsonrpc":"2.0","id":"1","result":null}"#,
                      #"{"jsonrpc":"2.0","id":1.5,"result":null}"#,
                      #"{"jsonrpc":"2.0","id":true,"result":null}"#,
                      #"{"jsonrpc":"2.0","method":"x","id":null}"#,
                      #"{"jsonrpc":"2.0","method":"x","result":null}"#,
                      #"{"jsonrpc":"2.0","method":"x","params":true}"#,
                      #"{"jsonrpc":"2.0","id":1,"error":{"code":1}}"#, "[]", "", "{}\n{}\n"])
    func malformedEnvelopesAreRefused(line: String) {
        #expect(throws: ACPJSONRPCError.malformedFrame) { try ACPJSONRPC.decode(Data(line.utf8)) }
    }

    @Test func invalidUTF8AndDuplicateEnvelopeKeysAreRefused() {
        #expect(throws: ACPJSONRPCError.malformedFrame) { try ACPJSONRPC.decode(Data([255])) }
        let line = #"{"jsonrpc":"2.0","id":1,"\u0069d":2,"result":null}"#
        #expect(throws: ACPJSONRPCError.malformedFrame) { try ACPJSONRPC.decode(Data(line.utf8)) }
    }
}
