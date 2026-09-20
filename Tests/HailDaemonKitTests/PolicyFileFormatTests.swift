import Foundation
import Testing
@testable import HailDaemonKit

/// The policy file's shape: what decodes, what is refused, and the bytes the signature will cover.
@Suite struct PolicyFileFormatTests {
    let id = "tmux:claude-hail"
    let binding = "$1@1/%1:9"

    @Test func policyMutationsAndCodableRoundTrip() throws {
        var policy = Policy()
        try policy.allow(id, binding: binding)
        let changed = policy.setTier(.open, for: id)
        let unknownChanged = policy.setTier(.open, for: "tmux:nope")
        #expect(changed)
        #expect(!unknownChanged)
        #expect(policy.targets[id]?.tier == .open)
        let data = try Policy.encoder().encode(policy)
        #expect(try JSONDecoder().decode(Policy.self, from: data) == policy)
        policy.deny(id)
        #expect(policy.targets[id] == nil)
    }

    @Test func aMinimalDocumentDecodesWithTheDefaults() throws {
        let minimal = try JSONDecoder().decode(Policy.self, from: Data(#"{"version":1,"targets":{}}"#.utf8))
        #expect(minimal == Policy())
        let bare = try JSONDecoder().decode(Policy.self, from: Data(#"{"version":1}"#.utf8))
        #expect(bare.guardPatterns == DangerousPatternGuard.defaults)
        #expect(bare.deliveriesPerMinute == 30)
        #expect(throws: PolicyFormatError.missingVersion) {
            try JSONDecoder().decode(Policy.self, from: Data("{}".utf8))
        }
    }

    @Test func theSignedFileShapeIsPinned() throws {
        var policy = Policy(deliveriesPerMinute: 12)
        try policy.allow("tmux:a", binding: "$1@1/%1:1", tier: .open, capture: true)
        let golden = """
        {
          "deliveriesPerMinute" : 12,
          "targets" : {
            "tmux:a" : {
              "binding" : "$1@1/%1:1",
              "capture" : true,
              "tier" : "open"
            }
          },
          "version" : 1
        }
        """
        #expect(String(bytes: try Policy.encoder().encode(policy), encoding: .utf8) == golden)
        #expect(try JSONDecoder().decode(Policy.self, from: Data(golden.utf8)) == policy)
        // The default guard list is not written, so a fixed default reaches every install without a re-sign.
        #expect(!golden.contains("guardPatterns"))
        policy.guardPatterns = [GuardPattern(name: "hi", regex: "hi")]
        let custom = String(bytes: try Policy.encoder().encode(policy), encoding: .utf8) ?? ""
        #expect(custom.contains("guardPatterns"))
    }

    @Test func unknownKeysOtherVersionsBadRulesAndEmptyBindingsAreRefused() {
        func decode(_ json: String) throws -> Policy { try JSONDecoder().decode(Policy.self, from: Data(json.utf8)) }
        #expect(throws: PolicyFormatError.unknownKeys(["lockdown"])) {
            try decode(#"{"version":1,"lockdown":true}"#)
        }
        #expect(throws: PolicyFormatError.invalidRateLimit(0)) {
            try decode(#"{"version":1,"deliveriesPerMinute":0}"#)
        }
        #expect(throws: PolicyFormatError.unknownKeys(["signed"])) {
            try decode(#"{"version":1,"targets":{"tmux:a":{"tier":"open","capture":false,"binding":"b","#
                + #""signed":true}}}"#)
        }
        #expect(throws: PolicyFormatError.unknownKeys(["flags"])) {
            try decode(#"{"version":1,"guardPatterns":[{"name":"x","regex":"x","flags":"i"}]}"#)
        }
        #expect(throws: PolicyFormatError.unsupportedVersion(2)) { try decode(#"{"version":2}"#) }
        #expect(throws: PolicyFormatError.invalidGuardPattern("broken")) {
            try decode(#"{"version":1,"guardPatterns":[{"name":"broken","regex":"("}]}"#)
        }
        #expect(throws: PolicyFormatError.emptyBinding("tmux:a")) {
            try decode(#"{"version":1,"targets":{"tmux:a":{"tier":"open","capture":false,"binding":" "}}}"#)
        }
        #expect(throws: PolicyFormatError.invalidGuardPattern("broken")) {
            try PolicyEvaluator(policy: Policy(guardPatterns: [GuardPattern(name: "broken", regex: "(")]))
        }
    }

    @Test func emptyGuardsEmptyTargetAndDuplicateGuardNamesAreRefused() {
        func decode(_ json: String) throws -> Policy { try JSONDecoder().decode(Policy.self, from: Data(json.utf8)) }
        #expect(throws: PolicyFormatError.emptyGuardPatterns) {
            try decode(#"{"version":1,"guardPatterns":[]}"#)
        }
        #expect(throws: PolicyFormatError.emptyTargetID) {
            try decode(#"{"version":1,"targets":{"":{"tier":"open","capture":false,"binding":"b"}}}"#)
        }
        #expect(throws: PolicyFormatError.duplicateGuardName("same")) {
            try decode(#"{"version":1,"guardPatterns":[{"name":"same","regex":"a"},{"name":"same","regex":"b"}]}"#)
        }
        #expect(throws: PolicyFormatError.emptyGuardPatterns) {
            try PolicyEvaluator(policy: Policy(guardPatterns: []))
        }
        #expect(throws: PolicyFormatError.duplicateGuardName("same")) {
            try PolicyEvaluator(policy: Policy(guardPatterns: [
                GuardPattern(name: "same", regex: "a"), GuardPattern(name: "same", regex: "b")
            ]))
        }
        var policy = Policy()
        #expect(throws: PolicyFormatError.emptyTargetID) { try policy.allow("", binding: "b") }
    }
}
