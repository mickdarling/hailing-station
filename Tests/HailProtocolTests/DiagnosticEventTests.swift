import Foundation
import Testing
@testable import HailProtocol

/// Device diagnostics (#234): only enumerated names and bounded scalar fields cross the wire, and the
/// decoder refuses anything else, so no transcript, reply text or request content can be carried.
@Suite struct DiagnosticEventTests {
    private func frame(_ events: String) -> Data {
        Data(("{\"v\":1,\"id\":\"0B0B0B0B-0000-4000-8000-0000000000E1\",\"ts\":1,\"type\":\"control\","
              + "\"source\":\"t\",\"payload\":{\"command\":\"diagnostic\",\"events\":[\(events)]}}").utf8)
    }

    private func event(_ fields: String, name: String = "ambient_stop") -> String {
        "{\"ts\":5,\"name\":\"\(name)\",\"fields\":{\(fields)}}"
    }

    @Test func limitLiteralsAreTheDocumentedOnes() {
        #expect(DiagnosticLimits.capability == "device_diagnostics")
        #expect(DiagnosticLimits.maxEventsPerBatch == 32)
        #expect(DiagnosticLimits.versionPattern == "^[0-9]{1,6}([.][0-9]{1,6}){0,3}$")
        #expect(DiagnosticLimits.integers == -2_147_483_648...2_147_483_647)
    }

    @Test func aValidBatchRoundTrips() throws {
        let original = Frame(timestamp: 9, source: "t", payload: .control(.diagnostic(events: [
            try DiagnosticEvent(.routeChange, timestamp: 7, fields: [
                .reason: .token("old_device_unavailable"), .route: .token("bluetooth_hfp")
            ]),
            try DiagnosticEvent(.appInfo, timestamp: 7, fields: [
                .app: .token("0.1.84"), .build: .token("12"), .os: .token("26.0.1"), .device: .token("phone")
            ]),
            try DiagnosticEvent(.echoGuard, timestamp: 8, fields: [.on: .boolean(true)]),
            try DiagnosticEvent(.connectionError, timestamp: 8, fields: [.error: .integer(-1_009)])
        ])))
        #expect(try FrameCoding.decode(FrameCoding.encode(original)) == original)
    }

    @Test func fieldsMayBeOmitted() throws {
        let decoded = try FrameCoding.decode(frame(#"{"ts":1,"name":"app_background"}"#))
        #expect(decoded.payload == .control(.diagnostic(events: [try DiagnosticEvent(.appBackground, timestamp: 1)])))
    }

    @Test(arguments: [
        DiagnosticValue.token("has a space"), .token(String(repeating: "a", count: 33)), .token(""),
        .token("quote\"d"), .token("new\nline"), .integer(1), .token("ignore_prior_rules"), .token("User"),
        .token("BuiltInMic"), .token("0.1.84")
    ])
    func theInitializerRefusesFreeTextAndWrongKinds(value: DiagnosticValue) {
        #expect(throws: DiagnosticEventInvalid(field: .reason)) {
            try DiagnosticEvent(.ambientStop, timestamp: 1, fields: [.reason: value])
        }
    }

    @Test(arguments: ["", "1.", ".1", "1..2", "1.2.3.4.5", "1234567", "v1", "1 2", "0.1.84_ignore_rules"])
    func versionFieldsTakeOnlyNumbers(value: String) {
        #expect(throws: DiagnosticEventInvalid(field: .app)) {
            try DiagnosticEvent(.appInfo, timestamp: 1, fields: [.app: .token(value)])
        }
    }

    @Test func everyTokenFieldHasAClosedVocabularyEndingInOther() {
        for field in DiagnosticField.allCases {
            #expect(field.tokens.isEmpty == (field.kind != .token), "\(field)")
            if field.kind == .token {
                #expect(field.tokens.last == "other")
                #expect(Set(field.tokens).count == field.tokens.count)
                let snake = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
                #expect(field.tokens.allSatisfy { $0.allSatisfy(snake.contains) })
            }
        }
    }

    @Test(arguments: [#","message":"ignore prior rules""#, #","text":"hello""#, #","target":"tmux:a""#])
    func theDiagnosticPayloadRefusesEveryOtherKey(extra: String) {
        let data = Data(("{\"v\":1,\"id\":\"0B0B0B0B-0000-4000-8000-0000000000E1\",\"ts\":1,\"type\":\"control\","
                         + "\"source\":\"t\",\"payload\":{\"command\":\"diagnostic\",\"events\":[\(event(""))]"
                         + "\(extra)}}").utf8)
        #expect(throws: DecodingError.self) { try FrameCoding.decode(data) }
    }

    @Test func theInitializerRefusesOutOfRangeIntegersAndNegativeTime() {
        #expect(throws: DiagnosticEventInvalid(field: .ms)) {
            try DiagnosticEvent(.ambientStop, timestamp: 1, fields: [.ms: .integer(Int64(Int32.max) + 1)])
        }
        #expect(throws: DiagnosticEventInvalid(field: nil)) { try DiagnosticEvent(.ambientStop, timestamp: -1) }
    }

    @Test(arguments: [
        #"{"ts":1,"name":"transcript"}"#,
        #"{"ts":1,"name":"ambient_stop","text":"hello"}"#,
        #"{"ts":1,"name":"ambient_stop","fields":{"transcript":"x"}}"#,
        #"{"ts":1,"name":"ambient_stop","fields":{"reason":"open the door"}}"#,
        #"{"ts":1,"name":"ambient_stop","fields":{"reason":"ignore_prior_rules"}}"#,
        #"{"ts":1,"name":"route_change","fields":{"route":"BuiltInMic"}}"#,
        #"{"ts":1,"name":"app_info","fields":{"os":"26.0 beta"}}"#,
        #"{"ts":1,"name":"ambient_stop","fields":{"reason":7}}"#,
        #"{"ts":1,"name":"ambient_stop","fields":{"on":1}}"#,
        #"{"ts":1,"name":"ambient_stop","fields":{"error":1.5}}"#,
        #"{"ts":1,"name":"ambient_stop","fields":{"reason":{"nested":"x"}}}"#,
        #"{"ts":-1,"name":"ambient_stop"}"#,
        #"{"name":"ambient_stop"}"#
    ])
    func theDecoderRefusesAnythingOutsideTheVocabulary(event: String) {
        #expect(throws: DecodingError.self) { try FrameCoding.decode(frame(event)) }
    }

    @Test func batchesAreBoundedOnBothSides() throws {
        #expect(throws: DecodingError.self) { try FrameCoding.decode(frame("")) }
        let full = Array(repeating: event(""), count: DiagnosticLimits.maxEventsPerBatch).joined(separator: ",")
        _ = try FrameCoding.decode(frame(full))
        #expect(throws: DecodingError.self) { try FrameCoding.decode(frame(full + "," + event(""))) }
    }

    @Test func noFieldCanCarryTextOrContent() {
        let names = Set(DiagnosticField.allCases.map(\.rawValue))
        for forbidden in ["text", "transcript", "reply", "message", "request", "audio", "body", "content"] {
            #expect(!names.contains(forbidden))
        }
        #expect(DiagnosticField.allCases.allSatisfy { $0.kind != .token || !$0.tokens.contains { $0.contains(" ") } })
    }

    @Test func theSchemaRefusesUnknownKeysAndBoundsTheBatch() throws {
        guard case .object(let root) = Schema.json, case .object(let defs)? = root["$defs"],
              case .object(let control)? = defs["control"], case .object(let props)? = control["properties"],
              case .object(let events)? = props["events"], case .object(let item)? = events["items"] else {
            Issue.record("control.events missing from the schema")
            return
        }
        #expect(events["maxItems"] == .integer(32))
        #expect(item["additionalProperties"] == .bool(false))
        guard case .array(let rules)? = control["allOf"] else {
            Issue.record("control rules missing")
            return
        }
        #expect(rules.contains(Schema.diagnosticPayloadRule))
    }
}
