import Foundation
import Testing
@testable import HailCore

/// #269/#225: advice is untrusted suggestion data, never host control or tool/action authority.
@Suite struct CoachingWireAdviceTests {
    @Test func authoredContractAdviceDecodesAndControlsAreNotAdvice() throws {
        let fixture = try coachingWireFixture()
        let advice = try CoachingWireAdvice.decode(fixture[2])
        #expect(advice.listenerID == "private-coach" && advice.validForMs == 1_000)
        #expect(advice.text == "Ask which assumption matters most before proposing a solution.")
        for index in [0, 1, 3, 4] {
            #expect(throws: CoachingWireError.invalidMessage) { try CoachingWireAdvice.decode(fixture[index]) }
        }
    }

    @Test func wrongTypesUnknownFieldsAndUnsafeValuesAreRejected() throws {
        let mutations: [(String, Any)] = [
            ("schema_version", 2), ("schema_version", true), ("schema_version", 1.5),
            ("valid_for_ms", 0), ("valid_for_ms", 2_001), ("valid_for_ms", true), ("valid_for_ms", "1000"),
            ("delivery", "room"), ("type", "coaching_control"), ("listener_id", "wrong\nlistener"),
            ("text", " "), ("text", "private\ntext"), ("text", String(repeating: "a", count: 281)),
            ("text", String(repeating: "a ", count: 46)), ("extra", "tool-grant"), ("session_id", "not-a-uuid"),
            ("session_id", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), ("provider", "not-a-top-level-field")
        ]
        for (key, value) in mutations {
            var object = try coachingWireObject()
            object[key] = value
            let data = try coachingWireData(object)
            #expect(throws: CoachingWireError.invalidMessage) { try CoachingWireAdvice.decode(data) }
        }
    }

    @Test func ambiguousNumbersDuplicateEscapedKeysAndNestedKeysAreRejected() throws {
        let fixture = try coachingWireFixture()[2]
        let source = try #require(String(data: fixture, encoding: .utf8))
        let invalid = [
            source.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":1.0"),
            source.replacingOccurrences(of: "\"valid_for_ms\":1000", with: "\"valid_for_ms\":1e3"),
            source.replacingOccurrences(of: "\"text\":", with: "\"text\":\"first\",\"text\":"),
            source.replacingOccurrences(of: "\"text\":", with: "\"te\\u0078t\":\"first\",\"text\":"),
            source.replacingOccurrences(of: "\"confidence\":1.0", with: "\"confidence\":0,\"confidence\":1.0"),
            source.replacingOccurrences(of: "\"confidence\":1.0", with: "\"confidence\":true"),
            source.replacingOccurrences(of: "\"confidence\":1.0", with: "\"confidence\":1e999"),
            source.replacingOccurrences(of: "\"label\":\"speak_now\"", with: "\"label\":\"invoke_tool\"")
        ]
        for candidate in invalid {
            #expect(throws: CoachingWireError.invalidMessage) { try CoachingWireAdvice.decode(Data(candidate.utf8)) }
        }
    }

    @Test func identifierUnicodeTextAndRawLineBounds() throws {
        var object = try coachingWireObject()
        var decision = try #require(object["decision"] as? [String: Any])
        decision["provider"] = String(repeating: "a", count: 96)
        decision["model"] = "Mock Model-1.0"
        object["decision"] = decision
        #expect(throws: Never.self) { try CoachingWireAdvice.decode(coachingWireData(object)) }
        decision["provider"] = String(repeating: "a", count: 97)
        object["decision"] = decision
        #expect(throws: CoachingWireError.invalidMessage) { try CoachingWireAdvice.decode(coachingWireData(object)) }
        let fixture = try #require(String(data: coachingWireFixture()[2], encoding: .utf8))
        let unicode = fixture.replacingOccurrences(
            of: "Ask which assumption matters most before proposing a solution.",
            with: "\\u00e9 \\\"text\\\": stays advice"
        )
        #expect(try CoachingWireAdvice.decode(Data(unicode.utf8)).text == "é \"text\": stays advice")
        #expect(throws: CoachingWireError.invalidMessage) {
            try CoachingWireAdvice.decode(Data(repeating: 32, count: 8_193))
        }
    }
}
