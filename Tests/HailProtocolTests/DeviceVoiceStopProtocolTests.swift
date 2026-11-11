import Foundation
import Testing
@testable import HailProtocol

@Suite struct DeviceVoiceStopProtocolTests {
    @Test(arguments: [nil, 0, 123, 60_000] as [Int?])
    func contentFreeReportRoundTrips(latency: Int?) throws {
        let payload = ControlPayload.voiceStopped(latencyMs: latency)
        let frame = Frame(timestamp: 1, source: "synthetic-device", payload: .control(payload))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["command"] as? String == "voice_stopped")
        #expect(object["latency_ms"] as? Int == latency)
        #expect(Set(object.keys) == (latency == nil ? ["command"] : ["command", "latency_ms"]))
    }

    @Test(arguments: ["-1", "60001", "1.5", "true", "null", "\"12\"", "[]", "{}", "9223372036854775808"])
    func latencyMustBeABoundedInteger(raw: String) {
        let json = #"{"command":"voice_stopped","latency_ms":\#(raw)}"#
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test(arguments: ["text", "audio", "target", "scope", "reason", "turn", "unknown"])
    func unknownKeysCannotCarryContentOrAuthority(key: String) {
        let json = #"{"command":"voice_stopped","\#(key)":"synthetic"}"#
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test(arguments: [-1, 60_001])
    func encoderAlsoRefusesOutOfBoundsLatency(latency: Int) {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(ControlPayload.voiceStopped(latencyMs: latency))
        }
    }

    @Test func helperRequiresTheHostsCapabilityAndValidLatency() {
        #expect(DeviceVoiceStop.capability == "device_voice_stop")
        #expect(DeviceVoiceStop.report(latencyMs: 42, hostCapabilities: []) == nil)
        #expect(DeviceVoiceStop.report(latencyMs: nil, hostCapabilities: [PlaybackStop.capability]) == nil)
        let capabilities = [DeviceVoiceStop.capability]
        #expect(DeviceVoiceStop.report(latencyMs: 42, hostCapabilities: capabilities) == .voiceStopped(latencyMs: 42))
        #expect(DeviceVoiceStop.report(latencyMs: nil, hostCapabilities: capabilities) == .voiceStopped(latencyMs: nil))
        #expect(DeviceVoiceStop.report(latencyMs: -1, hostCapabilities: capabilities) == nil)
    }

    @Test func schemaClosesTheCommandAndBoundsOptionalLatency() throws {
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Schema.json))
                                 as? [String: Any])
        let defs = try #require(object["$defs"] as? [String: Any])
        let control = try #require(defs["control"] as? [String: Any])
        let fields = try #require(control["properties"] as? [String: Any])
        let command = try #require(fields["command"] as? [String: Any])
        #expect((command["enum"] as? [String])?.contains("voice_stopped") == true)
        let rules = try #require(control["allOf"] as? [[String: Any]])
        let rule = try #require(rules.first { rule in
            let condition = rule["if"] as? [String: Any]
            let properties = condition?["properties"] as? [String: Any]
            return (properties?["command"] as? [String: Any])?["const"] as? String == "voice_stopped"
        })
        let then = try #require(rule["then"] as? [String: Any])
        #expect(then["additionalProperties"] as? Bool == false)
        let properties = try #require(then["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["command", "latency_ms"])
        let latency = try #require(properties["latency_ms"] as? [String: Any])
        #expect(latency["type"] as? String == "integer")
        #expect(latency["minimum"] as? Int == 0)
        #expect(latency["maximum"] as? Int == 60_000)
        #expect(then["required"] == nil)
    }

    private func decode(_ json: String) throws -> ControlPayload {
        try JSONDecoder().decode(ControlPayload.self, from: Data(json.utf8))
    }
}
