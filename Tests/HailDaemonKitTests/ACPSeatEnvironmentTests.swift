import Testing
@testable import HailDaemonKit

@Suite struct ACPSeatEnvironmentTests {
    @Test func credentialsAreRemovedAndReportedByNameOnly() throws {
        let names = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                     "OPENAI_API_KEY", "CODEX_API_KEY"]
        var base = Dictionary(uniqueKeysWithValues: names.map { ($0, "synthetic-secret") })
        base["HOME"] = "/synthetic/home"
        let built = try ACPSeatEnvironment(base: base)
        #expect(built.environment == ["HOME=/synthetic/home"])
        #expect(built.removedNames == names.sorted())
        #expect(!String(describing: built).contains("synthetic-secret"))
    }

    @Test func everyOtherKeyIncludingHarnessConfigurationIsKept() throws {
        let base = ["HOME": "/synthetic/home", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                    "ANTHROPIC_BASE_URL": "https://example.invalid", "OPENAI_BASE_URL": "https://example.invalid",
                    "CLAUDE_CODE_USE_BEDROCK": "1", "OTHER_TOKEN": "synthetic", "EMPTY": "", "a b": "x=y 🛰"]
        let built = try ACPSeatEnvironment(base: base)
        #expect(built.environment == base.map { "\($0.key)=\($0.value)" }.sorted())
        #expect(built.removedNames.isEmpty)
    }

    @Test func pathOverrideAppliesIncludingEmptyAndAbsentPaths() throws {
        for base in [["HOME": "/synthetic/home"], ["HOME": "/synthetic/home", "PATH": "/old"]] {
            for override in ["/synthetic/bin:/usr/bin", ""] {
                let built = try ACPSeatEnvironment(base: base, pathOverride: override)
                #expect(built.environment == ["HOME=/synthetic/home", "PATH=\(override)"])
            }
        }
    }

    @Test(arguments: [[:], ["HOME": "relative"], ["HOME": ""], ["HOME": "~/home"]])
    func homeMissingOrRelativeThrows(base: [String: String]) {
        #expect(throws: ACPSeatEnvironmentError.invalidHome) { try ACPSeatEnvironment(base: base) }
    }

    @Test(arguments: ["\0", "\n", "\r", "\t", "\u{1b}", "\u{7f}", "\u{85}"])
    func controlCharactersInKeysValuesAndOverridesThrow(control: String) {
        for base in [["HOME": "/home", "bad\(control)key": "value"],
                     ["HOME": "/home", "KEY": "bad\(control)value"],
                     ["HOME": "/home", "OPENAI_API_KEY": control],
                     ["HOME": "/home", "PATH": control]] {
            #expect(throws: ACPSeatEnvironmentError.invalidEntry) {
                try ACPSeatEnvironment(base: base, pathOverride: "/valid")
            }
        }
        #expect(throws: ACPSeatEnvironmentError.invalidEntry) {
            try ACPSeatEnvironment(base: ["HOME": "/home"], pathOverride: control)
        }
    }

    @Test(arguments: ["", "=", "BAD=KEY"])
    func emptyAndEqualsKeysThrow(key: String) {
        #expect(throws: ACPSeatEnvironmentError.invalidEntry) {
            try ACPSeatEnvironment(base: ["HOME": "/home", key: "value"])
        }
    }

    @Test func outputIsSortedAndStableAcrossInsertionOrders() throws {
        let entries = [("Z", "last"), ("HOME", "/home"), ("A", "first"), ("A-", "prefix"),
                       ("OPENAI_API_KEY", "synthetic")]
        let first = try ACPSeatEnvironment(base: Dictionary(uniqueKeysWithValues: entries))
        let second = try ACPSeatEnvironment(base: Dictionary(uniqueKeysWithValues: entries.reversed()))
        #expect(first == second)
        #expect(first.environment == ["A-=prefix", "A=first", "HOME=/home", "Z=last"])
    }
}
