import HailDaemonKit
import HailProtocol
import Testing

/// #1120: the proposed wire vocabulary must cover every daemon default without exposing configured names.
@Suite struct HeldRequestRuleVocabularyTests {
    @Test func everyDaemonDefaultHasAClosedWireRule() throws {
        var covered = Set<HeldRequestRule>()
        for pattern in DangerousPatternGuard.defaults {
            // The proposed contract collapses runs of spaces/hyphens in built-in names to one underscore.
            let token = pattern.name.split { $0 == " " || $0 == "-" }.joined(separator: "_")
            let rule = try #require(HeldRequestRule(rawValue: token), "missing wire rule for \(pattern.name)")
            #expect(rule != .custom)
            covered.insert(rule)
        }
        #expect(covered == Set(HeldRequestRule.allCases.filter { $0 != .custom }))
    }
}
