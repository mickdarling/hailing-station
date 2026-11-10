import Foundation
import Testing
@testable import HailDaemonKit

/// Slice 1 configuration: strict version-1 coding without changing admission.
@Suite struct VoiceGuardsPolicyCodingTests {
    private func decode(_ json: String) throws -> Policy {
        try JSONDecoder().decode(Policy.self, from: Data(json.utf8))
    }

    @Test func absentDefaultsOn() throws {
        #expect(Policy().voiceGuards == .on)
        #expect(try decode(#"{"version":1}"#).voiceGuards == .on)
    }

    @Test(arguments: ["on", "off"])
    func exactStringsDecode(_ raw: String) throws {
        let policy = try decode("{\"version\":1,\"voiceGuards\":\"\(raw)\"}")
        #expect(policy.voiceGuards.rawValue == raw)
    }

    @Test(arguments: ["null", "true", "false", "0", "1.5", #""ON""#, #"" off""#, #""""#, #""unknown""#, "{}", "[]"])
    func everyOtherValueIsRefused(_ value: String) {
        #expect(throws: PolicyFormatError.invalidVoiceGuards("expected exactly the string \"on\" or \"off\"")) {
            try decode("{\"version\":1,\"voiceGuards\":\(value)}")
        }
    }

    @Test(arguments: VoiceGuards.allCases)
    func reproducibleRoundTripOmitsOnlyOn(_ setting: VoiceGuards) throws {
        let policy = Policy(voiceGuards: setting)
        let encoded = try Policy.encoder().encode(policy)
        #expect(encoded == (try Policy.encoder().encode(policy)))
        #expect(try JSONDecoder().decode(Policy.self, from: encoded) == policy)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(Policy.version == 1)
        if setting == .on {
            #expect(object["voiceGuards"] == nil)
        } else {
            #expect(object["voiceGuards"] as? String == "off")
        }
        let keys = object.keys.sorted()
        let text = try #require(String(data: encoded, encoding: .utf8))
        let offsets = try keys.map { key in try #require(text.range(of: "\"\(key)\"")?.lowerBound) }
        #expect(offsets == offsets.sorted())
    }

    @Test func offStillRefusesUnknownKeysAndInvalidGuards() {
        #expect(throws: PolicyFormatError.unknownKeys(["future"])) {
            try decode(#"{"version":1,"voiceGuards":"off","future":true}"#)
        }
        #expect(throws: PolicyFormatError.unknownKeys(["future"])) {
            try decode(#"{"version":1,"voiceGuards":"off","guardPatterns":[{"name":"a","regex":"a","future":1}]}"#)
        }
        #expect(throws: PolicyFormatError.emptyGuardPatterns) {
            try decode(#"{"version":1,"voiceGuards":"off","guardPatterns":[]}"#)
        }
        #expect(throws: PolicyFormatError.invalidGuardPattern("broken")) {
            try decode(#"{"version":1,"voiceGuards":"off","guardPatterns":[{"name":"broken","regex":"("}]}"#)
        }
        #expect(throws: PolicyFormatError.duplicateGuardName("a")) {
            try decode("""
            {"version":1,"voiceGuards":"off","guardPatterns":[{"name":"a","regex":"a"},{"name":"a","regex":"b"}]}
            """)
        }
        #expect(throws: PolicyFormatError.unsupportedVersion(2)) {
            try decode(#"{"version":2,"voiceGuards":"off"}"#)
        }
    }
}
