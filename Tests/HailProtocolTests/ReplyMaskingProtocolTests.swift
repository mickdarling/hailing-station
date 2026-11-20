import Foundation
@testable import HailProtocol
import Testing

@Suite struct ReplyMaskingProtocolTests {
    @Test(arguments: [false, true])
    func strictHostDecoderAcceptsOldAndNewDevices(present: Bool) throws {
        let fields: [DiagnosticField: DiagnosticValue] = present
            ? [.masking: .boolean(false), .reason: .token("plain_capture"), .capture: .token("plain"),
               .ms: .integer(1_400), .count: .integer(1)] : [.on: .boolean(false), .ms: .integer(400)]
        let event = try DiagnosticEvent(.echoGuard, timestamp: 1, fields: fields)
        let frame = Frame(timestamp: 1, source: "synthetic", payload: .control(.diagnostic(events: [event])))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
        #expect(DiagnosticLimits.replyMaskingCapability == "device_diagnostics_reply_masking")
    }

    @Test func maskingFieldsRejectContentAndWrongKinds() {
        for field in [DiagnosticField.masking, .capture, .reason] {
            for value in ["synthetic private text", "request_id", "reply_id", UUID().uuidString] {
                #expect(throws: DiagnosticEventInvalid(field: field)) {
                    try DiagnosticEvent(.echoGuard, timestamp: 1, fields: [field: .token(value)])
                }
            }
        }
        #expect(DiagnosticField.capture.tokens == ["plain", "vpio", "other"])
        #expect(DiagnosticField.masking.kind == .boolean)
    }

    @Test func checkedInSchemaMatchesTheGenerator() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: root.appendingPathComponent("fixtures/schema/frame-v1.schema.json"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: fixture) == Schema.json)
    }

    @Test func generatedSchemaHasTheSameClosedFieldsAndReasons() throws {
        let encoded = try FrameCoding.encoder().encode(Schema.json)
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let defs = try #require(root["$defs"] as? [String: Any])
        let control = try #require(defs["control"] as? [String: Any])
        let props = try #require(control["properties"] as? [String: Any])
        let events = try #require(props["events"] as? [String: Any])
        let item = try #require(events["items"] as? [String: Any])
        let itemProps = try #require(item["properties"] as? [String: Any])
        let fields = try #require(itemProps["fields"] as? [String: Any])
        let fieldProps = try #require(fields["properties"] as? [String: [String: Any]])
        #expect(fieldProps["masking"]?["type"] as? String == "boolean")
        #expect(fieldProps["capture"]?["enum"] as? [String] == DiagnosticField.capture.tokens)
        #expect(fieldProps["reason"]?["enum"] as? [String] == DiagnosticField.reason.tokens)
        #expect(fields["additionalProperties"] as? Bool == false)
        #expect(Set(fieldProps.keys) == Set(DiagnosticField.allCases.map(\.rawValue)))
        for key in ["count", "ms"] {
            #expect(fieldProps[key]?["type"] as? String == "integer")
            #expect(fieldProps[key]?["minimum"] as? Int64 == DiagnosticLimits.integers.lowerBound)
            #expect(fieldProps[key]?["maximum"] as? Int64 == DiagnosticLimits.integers.upperBound)
        }
    }

    @Test func allReasonCaptureAndEdgeCombinationsRoundTrip() throws {
        var events = [
            try DiagnosticEvent(.captureState, timestamp: 1, fields: [.capture: .token("vpio")]),
            try DiagnosticEvent(.echoGuard, timestamp: 1, fields: [.on: .boolean(true)]),
            try DiagnosticEvent(.echoGuard, timestamp: 1, fields: [.on: .boolean(false), .ms: .integer(400)])
        ]
        for reason in ["setting", "reply_not_routed", "plain_capture", "tap_to_talk"] {
            for capture in ["plain", "vpio", "other"] {
                for masking in [true, false] {
                    events.append(try DiagnosticEvent(.echoGuard, timestamp: 1, fields: [
                        .masking: .boolean(masking), .reason: .token(reason), .capture: .token(capture),
                        .count: .integer(1), .ms: .integer(400)
                    ]))
                }
            }
        }
        let frame = Frame(timestamp: 1, source: "synthetic", payload: .control(.diagnostic(events: events)))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }

    @Test(arguments: [
        #"{"masking":"true"}"#, #"{"capture":"private text"}"#, #"{"reason":"private text"}"#,
        #"{"capture":"unknown_engine"}"#, #"{"masking":true,"reply_id":"synthetic"}"#,
        #"{"masking":true,"request_id":"synthetic"}"#, #"{"audio":"synthetic"}"#
    ])
    func strictDecoderRejectsContentUnknownTokensAndWrongKinds(fields: String) throws {
        let envelope = #"{"v":1,"id":"00000000-0000-4000-8000-000000001213","ts":1,"#
            + #""type":"control","source":"synthetic","payload":{"command":"diagnostic","events":["#
            + #"{"ts":1,"name":"echo_guard","fields":\#(fields)}]}}"#
        let valid = envelope.replacingOccurrences(of: fields, with: #"{"masking":true}"#)
        _ = try FrameCoding.decode(Data(valid.utf8))
        #expect(throws: DecodingError.self) { try FrameCoding.decode(Data(envelope.utf8)) }
    }
}
