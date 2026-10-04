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
        #expect(DiagnosticLimits.maxTokenLength == 32)
        #expect(DiagnosticLimits.integers == -2_147_483_648...2_147_483_647)
    }

    @Test func aValidBatchRoundTrips() throws {
        let original = Frame(timestamp: 9, source: "t", payload: .control(.diagnostic(events: [
            try DiagnosticEvent(.routeChange, timestamp: 7, fields: [
                .reason: .token("old_device_unavailable"), .route: .token("BluetoothHFP")
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
        .token("quote\"d"), .token("new\nline"), .integer(1)
    ])
    func theInitializerRefusesFreeTextAndWrongKinds(value: DiagnosticValue) {
        #expect(throws: DiagnosticEventInvalid(field: .reason)) {
            try DiagnosticEvent(.ambientStop, timestamp: 1, fields: [.reason: value])
        }
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
        let eventNames = DiagnosticEventName.allCases.map(\.rawValue)
        #expect(eventNames.allSatisfy(DiagnosticLimits.isToken))
        #expect(!DiagnosticLimits.tokenCharacters.contains(" "))
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
    }
}
