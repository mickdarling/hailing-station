import Foundation
import HailProtocol
import Testing

/// #1120: closed vocabularies must exclude arbitrary metadata even when it looks like a machine token.
@Suite struct HeldRequestsVocabularyTests {
    private let held = UUID(uuidString: "00000000-0000-4000-8000-000000001120")

    @Test func frozenRuleMappingKeepsUnknownAndConfiguredNamesPrivate() throws {
        let frozen = Set(["rm_rf", "sudo", "force_push", "git_reset_hard", "git_clean", "destructive_git",
                          "branch_delete", "delete", "disk_write", "permissions", "shell", "fork_bomb",
                          "credential", "custom"])
        #expect(Set(HeldRequestRule.allCases.map(\.rawValue)) == frozen)
        for rule in HeldRequestRule.allCases {
            #expect(HeldRequestRule.wireRule(for: rule.rawValue, isBuiltIn: true) == rule)
            #expect(HeldRequestRule.wireRule(for: rule.rawValue, isBuiltIn: false) == .custom)
        }
        #expect(HeldRequestRule.wireRule(for: "git reset --hard", isBuiltIn: true) == .gitResetHard)
        #expect(HeldRequestRule.wireRule(for: "rm -rf", isBuiltIn: true) == .rmRF)
        for name in ["future built-in", "private pattern=.*", "SUDO", "", "deadbeef"] {
            for isBuiltIn in [false, true] {
                let rule = HeldRequestRule.wireRule(for: name, isBuiltIn: isBuiltIn)
                #expect(rule == .custom)
                let notice = RequestHeld(held: try #require(held), reasons: [.ruleMatch, .guardTimeout],
                                         rules: [rule], expiresIn: 60)
                let decoded = try JSONDecoder().decode(RequestHeld.self, from: JSONEncoder().encode(notice))
                #expect(decoded.rules == [.custom])
                #expect(decoded.reasons == [.ruleMatch, .guardTimeout])
            }
        }
    }

    @Test(arguments: HeldRequestRefusalReason.allCases)
    func everyRefusalReasonRoundTrips(reason: HeldRequestRefusalReason) throws {
        let payload = ControlPayload.heldResolution(HeldResolution(
            held: try #require(held), outcome: .refused, reason: reason))
        let frame = Frame(timestamp: 1, source: "synthetic", payload: .control(payload))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["reason"] as? String == reason.rawValue)
    }

    @Test(arguments: ["alice", "synthetic_name", "delete_database", "deadbeef", "0123456789abcdef0123456789abcdef",
                      String(repeating: "a", count: 40), String(repeating: "b", count: 64)])
    func arbitraryNamesContentAndHashesAreRefused(token: String) throws {
        let identifier = try #require(held).uuidString
        let payloads: [[String: Any]] = [
            ["command": "request_held", "held": identifier, "reasons": ["rule_match"],
             "rules": [token], "expires_in": 60],
            ["command": "held_resolution", "held": identifier, "outcome": "refused", "reason": token]
        ]
        for payload in payloads {
            let data = try JSONSerialization.data(withJSONObject: payload)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ControlPayload.self, from: data) }
        }
        #expect(HeldRequestRule(rawValue: token) == nil)
        #expect(HeldRequestRefusalReason(rawValue: token) == nil)
    }
}
