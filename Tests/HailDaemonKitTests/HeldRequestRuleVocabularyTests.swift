import HailDaemonKit
import HailProtocol
import Testing

/// #1120: new defaults may use `custom`; the capability's wire vocabulary must remain frozen.
@Suite struct HeldRequestRuleVocabularyTests {
    @Test func everyDaemonDefaultMapsToAFrozenWireRule() {
        let frozen = Set(["rm_rf", "sudo", "force_push", "git_reset_hard", "git_clean", "destructive_git",
                          "branch_delete", "delete", "disk_write", "permissions", "shell", "fork_bomb",
                          "credential", "custom"])
        for pattern in DangerousPatternGuard.defaults {
            let rule = HeldRequestRule.wireRule(for: pattern.name, isBuiltIn: true)
            #expect(frozen.contains(rule.rawValue))
        }
        // A future default needs no new capability token, and configured names never inherit built-in metadata.
        #expect(HeldRequestRule.wireRule(for: "future default", isBuiltIn: true) == .custom)
        #expect(HeldRequestRule.wireRule(for: "sudo", isBuiltIn: false) == .custom)
    }
}
