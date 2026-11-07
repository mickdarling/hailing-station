import Foundation
import HailProtocol
import HailProtocolFixtures
import Testing

/// #1120 PR 1: synthetic protocol proof only; no host delivery or phone UI is enabled.
@Suite struct HeldRequestsProtocolTests {
    private let held = UUID(uuidString: "00000000-0000-4000-8000-000000001120")
    private let turn = UUID(uuidString: "00000000-0000-4000-8000-000000000923")

    @Test(arguments: [false, true])
    func noticeRoundTripsWithMatchAndTimeout(carriesTurn: Bool) throws {
        let notice = RequestHeld(held: try #require(held), turn: carriesTurn ? try #require(turn) : nil,
                                 reasons: [.ruleMatch, .guardTimeout], rules: [.sudo, .custom], expiresIn: 60)
        try roundTrip(.requestHeld(notice))
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ControlPayload.requestHeld(notice))) as? [String: Any])
        #expect(object["command"] as? String == "request_held")
        #expect(object["expires_in"] as? Int == 60)
        #expect(object["reasons"] as? [String] == ["rule_match", "guard_timeout"])
        #expect(object["rules"] as? [String] == ["sudo", "custom"])
        #expect(object.keys.contains("turn") == carriesTurn)
        #expect(HeldRequests.capability == "held_requests")
    }
    @Test(arguments: HeldRequestReason.allCases)
    func everyReasonRoundTrips(reason: HeldRequestReason) throws {
        try roundTrip(.requestHeld(RequestHeld(held: try #require(held), reasons: [reason], rules: [], expiresIn: 1)))
    }
    @Test(arguments: HeldRequestAction.allCases)
    func everyDecisionRoundTrips(action: HeldRequestAction) throws {
        try roundTrip(.heldDecision(HeldDecision(held: try #require(held), action: action)))
    }
    @Test(arguments: HeldRequestOutcome.allCases)
    func everyResolutionRoundTrips(outcome: HeldRequestOutcome) throws {
        try roundTrip(.heldResolution(HeldResolution(held: try #require(held), outcome: outcome,
                                                    reason: outcome == .refused ? .policyChanged : nil)))
    }
    @Test func boundsAndAllBuiltInRulesRoundTrip() throws {
        let identifier = try #require(held)
        for expiry in [HeldRequests.expirySeconds.lowerBound, HeldRequests.expirySeconds.upperBound] {
            try roundTrip(.requestHeld(RequestHeld(held: identifier, reasons: HeldRequestReason.allCases,
                                                  rules: HeldRequestRule.allCases, expiresIn: expiry)))
        }
        try roundTrip(.requestHeld(RequestHeld(held: identifier, reasons: [.guardTimeout],
            rules: Array(repeating: .custom, count: HeldRequests.maxRules), expiresIn: 1)))
        #expect(HeldRequestRule.allCases.allSatisfy { $0.rawValue.utf8.count <= HeldRequests.maxRuleTokenBytes })
    }
    @Test(arguments: ["request_held", "held_decision", "held_resolution"])
    func requiredFieldsAndUnknownFieldsAreStrict(command: String) throws {
        let valid = try object(command)
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            try rejects(missing)
        }
        for key in ["text", "pattern", "target", "binding", "heldID", "turn", "unknown"] {
            var extra = valid
            extra[key] = "synthetic"
            try rejects(extra)
        }
    }
    @Test(arguments: ["future", "", "RULE_MATCH", "rule_match "])
    func unknownReasonsAreRefused(reason: String) throws {
        var value = try object("request_held")
        value["reasons"] = [reason]
        try rejects(value)
    }
    @Test(arguments: ["future", "", "SEND", "send "])
    func unknownActionsAreRefused(action: String) throws {
        var value = try object("held_decision")
        value["action"] = action
        try rejects(value)
    }
    @Test(arguments: ["future", "", "SENT", "sent "])
    func unknownOutcomesAreRefused(outcome: String) throws {
        var value = try object("held_resolution")
        value["outcome"] = outcome
        try rejects(value)
    }
    @Test func malformedReasonAndRuleListsAreRefused() throws {
        for reasons: Any in [[], ["rule_match", "rule_match"], Array(repeating: "rule_match", count: 5),
                             "rule_match", NSNull(), [1]] {
            var value = try object("request_held")
            value["reasons"] = reasons
            try rejects(value)
        }
        for rules: Any in [Array(repeating: "custom", count: HeldRequests.maxRules + 1),
                           [String(repeating: "a", count: HeldRequests.maxRuleTokenBytes + 1)],
                           ["private rule name"], ["sudo.*"], ["SUDO"], [""], ["rm -rf"], [1], "sudo", NSNull()] {
            var value = try object("request_held")
            value["rules"] = rules
            try rejects(value)
        }
    }
    @Test(arguments: ["not-a-uuid", "", "00000000000040008000000000001120",
                      "00000000-0000-4000-8000-000000001120\n"])
    func badUUIDsAreRefused(raw: String) throws {
        for command in ["request_held", "held_decision", "held_resolution"] {
            var value = try object(command)
            value["held"] = raw
            try rejects(value)
        }
        var value = try object("request_held")
        value["turn"] = raw
        try rejects(value)
    }
    @Test func nullAndWrongTypesAreRefused() throws {
        for command in ["request_held", "held_decision", "held_resolution"] {
            let valid = try object(command)
            for key in valid.keys where key != "command" {
                for wrong: Any in [NSNull(), false, [:]] {
                    var value = valid
                    value[key] = wrong
                    try rejects(value)
                }
            }
        }
        var value = try object("request_held")
        value["turn"] = NSNull()
        try rejects(value)
        value["turn"] = 123
        try rejects(value)
    }
    @Test func invalidExpiriesAreRefused() throws {
        for expiry: Any in [-1, 0, HeldRequests.expirySeconds.upperBound + 1, 1.5, "60", NSNull()] {
            var value = try object("request_held")
            value["expires_in"] = expiry
            try rejects(value)
        }
    }
}

extension HeldRequestsProtocolTests {
    @Test(arguments: ["", "not prose", "secret=pattern", "UPPER", "é", "line\nbreak",
                      "policy_changed ", "policy_changed\n"])
    func malformedRefusalTokensAreRefused(reason: String) throws {
        var value = try object("held_resolution")
        value["reason"] = reason
        try rejects(value)
    }
    @Test func refusalReasonIsRequiredOnlyForRefused() throws {
        for outcome in HeldRequestOutcome.allCases where outcome != .refused {
            var value = try object("held_resolution")
            value["outcome"] = outcome.rawValue
            try rejects(value)
        }
        var value = try object("held_resolution")
        value["reason"] = NSNull()
        try rejects(value)
    }
    @Test func invalidValuesCannotBeEncoded() throws {
        let identifier = try #require(held)
        for notice in [
            RequestHeld(held: identifier, reasons: [], rules: [], expiresIn: 60),
            RequestHeld(held: identifier, reasons: [.ruleMatch, .ruleMatch], rules: [], expiresIn: 60),
            RequestHeld(held: identifier, reasons: [.ruleMatch], rules: [], expiresIn: 0),
            RequestHeld(held: identifier, reasons: [.ruleMatch], rules: [], expiresIn: 3_601),
            RequestHeld(held: identifier, reasons: [.ruleMatch],
                        rules: Array(repeating: .custom, count: HeldRequests.maxRules + 1), expiresIn: 60)
        ] {
            #expect(throws: EncodingError.self) { try JSONEncoder().encode(ControlPayload.requestHeld(notice)) }
        }
        for resolution in [HeldResolution(held: identifier, outcome: .refused),
                           HeldResolution(held: identifier, outcome: .sent, reason: .policyChanged)] {
            #expect(throws: EncodingError.self) { try JSONEncoder().encode(ControlPayload.heldResolution(resolution)) }
        }
    }
    @Test func existingPayloadsDecodeUnchanged() throws {
        for fixture in Fixtures.all {
            #expect(try FrameCoding.decode(FrameCoding.encode(fixture.frame)) == fixture.frame)
        }
        let legacy = #"{"command":"error","code":"voice_route_refused","message":"synthetic","extension":true}"#
        #expect(try JSONDecoder().decode(ControlPayload.self, from: Data(legacy.utf8))
                == .error(code: .voiceRouteRefused, message: "synthetic"))
    }

    private func object(_ command: String) throws -> [String: Any] {
        let identifier = try #require(held).uuidString
        switch command {
        case "request_held":
            return ["command": command, "held": identifier, "reasons": ["rule_match"],
                    "rules": ["sudo"], "expires_in": 60]
        case "held_decision": return ["command": command, "held": identifier, "action": "send"]
        default: return ["command": command, "held": identifier, "outcome": "refused", "reason": "policy_changed"]
        }
    }

    private func rejects(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ControlPayload.self, from: data) }
    }

    private func roundTrip(_ payload: ControlPayload) throws {
        let frame = Frame(timestamp: 1, source: "synthetic", payload: .control(payload))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }
}
