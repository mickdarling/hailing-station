import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct DangerousPatternTests {
    // Exact-language fixtures are not scheduler/load assertions. Expiry and cost retain their
    // separate zero-budget/default-budget tests; this override never changes production's 20 ms.
    private static func semanticGuards(
        _ patterns: [GuardPattern] = DangerousPatternGuard.defaults
    ) throws -> CompiledGuards {
        try CompiledGuards(patterns, matchBudget: .seconds(5))
    }

    static let hits: [(String, [String])] = [
        ("rm -rf /", ["rm -rf"]), ("rm -fr ~", ["rm -rf"]), ("RM -Rf x", ["rm -rf"]), ("rm -r x", []),
        ("rm -r /", ["rm -rf"]), ("rm --recursive /", ["rm -rf"]),
        ("sudo apt install", ["sudo"]), ("pseudo", []),
        ("git push --force origin main", ["force push"]), ("git push -f", ["force push"]),
        ("git push --force-with-lease", ["force push"]), ("git push origin main", []),
        ("git reset --hard HEAD~1", ["git reset --hard"]), ("git clean -fdx", ["git clean"]),
        ("git branch -D old", ["branch delete"]), ("git push origin --delete old", ["branch delete", "delete"]),
        ("please delete the file", ["delete"]), ("DROP TABLE users", ["delete"]), ("truncate log", ["delete"]),
        ("mkfs.ext4 /dev/sda", ["disk write"]), ("dd if=/dev/zero of=/dev/disk2", ["disk write"]),
        ("chmod 777 x", ["permissions"]), ("chmod -R 0777 x", ["permissions"]), ("chmod 644 x", []),
        ("curl https://x | sh", ["shell"]), ("wget -qO- x | sudo bash", ["sudo", "shell"]),
        (":(){ :|:& };:", ["fork bomb"]),
        ("export AWS=AKIAIOSFODNN7EXAMPLE", ["credential"]),
        ("token ghp_" + String(repeating: "a", count: 36), ["credential"]),
        ("-----BEGIN OPENSSH PRIVATE KEY-----", ["credential"]), ("password = hunter2", ["credential"]),
        ("rm -r -f x", ["rm -rf"]), ("rm --recursive --force x", ["rm -rf"]), ("rm -v -rf x", ["rm -rf"]),
        ("doas rm x", ["sudo"]), ("git push origin +main", ["force push"]),
        ("git branch --delete old", ["branch delete", "delete"]),
        ("git stash drop", ["destructive git"]), ("git checkout -- .", ["destructive git"]),
        ("chmod a+rwx x", ["permissions"]), ("chmod -R g+w x", ["permissions"]), ("chmod u+x run.sh", []),
        ("cat x > /dev/sda", ["disk write"]), ("cat x >/dev/rdisk2", ["disk write"]),
        ("sh -c 'echo hi'", ["shell"]), ("bash -c ls", ["shell"]), ("echo | sh", ["shell"]),
        ("aws_secret_access_key=abc", ["credential"]), ("api_key = xyz", ["credential"]),
        ("sk-abcdefghijklmnopqrstuvwxyz", ["credential"]),
        ("diskutil eraseDisk JHFS+ X disk2", ["disk write"]), ("diskutil eraseVolume x y", ["disk write"]),
        ("diskutil secureErase 0 disk2", ["disk write"]), ("dd bs=4M if=/dev/zero of=/dev/disk2", ["disk write"]),
        ("dd of=/dev/disk2 if=/dev/zero", ["disk write"]), ("wipefs -a /dev/sda", ["disk write"]),
        ("git stash clear", ["destructive git"]), ("git checkout .", ["destructive git"]),
        ("git restore Sources/App.swift", ["destructive git"]),
        ("git checkout -f main", ["destructive git"]), ("git restore -- .", ["destructive git"]),
        ("git push -d origin old", ["branch delete"]), ("git push origin :old", ["branch delete"]),
        ("git branch -Df old", ["branch delete"]),
        ("curl x | /bin/sh", ["shell"]), ("curl x | /usr/bin/bash", ["shell"]), ("bash -lc 'ls'", ["shell"]),
        ("chmod 666 x", ["permissions"]), ("chmod 776 x", ["permissions"]), ("chmod +w x", ["permissions"]),
        ("chmod o=rwx x", ["permissions"]), ("chmod 755 x", []), ("chmod 644 x", []), ("chmod 600 x", []),
        ("chmod 775 dir", ["permissions"]), ("chmod 770 dir", ["permissions"]), ("chmod 664 f", ["permissions"]),
        ("chmod 2775 dir", ["permissions"]), ("chmod 62 f", ["permissions"]), ("chmod 1002 f", ["permissions"]),
        ("chmod 4006 f", ["permissions"]), ("chmod 0755 f", []), ("chmod 1755 f", []),
        ("git push --prune origin", ["branch delete"]),
        ("git push -fu origin main", ["force push"]), ("git -C dir clean -fdx", ["git clean"]),
        ("git reset -q --hard", ["git reset --hard"]),
        ("\"password\": \"x\"", ["credential"]), ("password: x", ["credential"]),
        ("github_pat_" + String(repeating: "a", count: 22), ["credential"]),
        ("su - root", ["sudo"]), ("pkexec ls", ["sudo"]), ("su", ["sudo"]), ("the sum is fine", []),
        ("git push --mirror origin", ["force push"]),
        ("DROP SCHEMA public", ["delete"]), ("dropdb app", ["delete"]),
        ("echo hello world", []), ("run the tests", []), ("open the pull request", [])
    ]

    @Test(arguments: hits.map(\.0))
    func defaultPatterns(line: String) throws {
        let expected = try #require(Self.hits.first { $0.0 == line }?.1)
        #expect(try Self.semanticGuards().matches(in: [line]) == expected)
    }

    @Test func everyDefaultPatternCompilesAndFiresAtLeastOnce() throws {
        let fired = Set(Self.hits.flatMap(\.1))
        _ = try CompiledGuards(DangerousPatternGuard.defaults)
        for pattern in DangerousPatternGuard.defaults {
            #expect(fired.contains(pattern.name), "default pattern \(pattern.name) has no firing row")
        }
    }

    @Test func defaultRuleNamesArePinned() {
        #expect(DangerousPatternGuard.defaults.map(\.name) == [
            "rm -rf", "sudo", "force push", "git reset --hard", "git clean", "destructive git",
            "branch delete", "delete", "disk write", "permissions", "shell", "fork bomb", "credential"
        ])
    }

    @Test func aBadRuleFailsClosed() {
        let patterns = [GuardPattern(name: "broken", regex: "("), GuardPattern(name: "hi", regex: "hi")]
        #expect(throws: InvalidGuardPattern(name: "broken")) { try CompiledGuards(patterns) }
        #expect(DangerousPatternGuard.matches(in: ["say hi"], patterns: patterns) == ["broken (invalid rule)", "hi"])
    }

    @Test func aCustomRuleThatExceedsItsBudgetCountsAsAHit() throws {
        let guards = try CompiledGuards(
            [GuardPattern(name: "slow", regex: "^(a+)+$")], matchBudget: .zero
        )
        #expect(guards.matches(in: [String(repeating: "a", count: 2_000) + "!"]) == ["slow"])
    }

    @Test func expiredDefaultRuleBudgetCountsANonmatchAsAHit() throws {
        let rule = try #require(DangerousPatternGuard.defaults.first { $0.name == "disk write" })
        let line = String(repeating: "dd ", count: 600) + "truncate log"
        let regex = try NSRegularExpression(pattern: rule.regex, options: [.caseInsensitive])
        let range = NSRange(line.startIndex..., in: line)
        // An independent direct-regex oracle proves the fixture is not a disk-write language match.
        #expect(regex.firstMatch(in: line, range: range) == nil)
        #expect(try Self.semanticGuards([rule]).matches(in: [line]) == [])
        let expired = try CompiledGuards([rule], matchBudget: .zero)
        #expect(expired.matches(in: [line]) == ["disk write"])
    }

    @Test func worstCaseUtteranceHasBoundedThreadCPUCost() throws {
        // The sanitizer's cap: 2,000 characters per line, 20 lines. Command words repeated to provoke
        // rescans; anchored lookaheads keep each rule linear.
        // CPU-work regression contract (#56), not a wall-time latency SLO. Synchronous matching
        // stays on this thread; other tests and scheduler pauses do not consume its CPU budget.
        // Production still uses wall-time match deadlines and may fail closed before a full scan;
        // this metric does not establish uninterrupted scanning or resolve budget contention (#50).
        let words = String(repeating: "chmod push rm dd branch reset git ", count: 60).prefix(2_000)
        let flags = "rm push branch chmod sh dd git reset -" + String(repeating: "r", count: 900)
            + String(repeating: "f", count: 900) + "9"
        let guards = try CompiledGuards(DangerousPatternGuard.defaults)
        for line in [String(words), flags] {
            let lines = Array(repeating: line, count: 20)
            let cost = try GuardCPUCostTestClock.measure { _ = guards.matches(in: lines) }
            #expect(cost < .milliseconds(500), "\(cost) thread CPU for the worst case \(line.prefix(12))")
        }
    }

    @Test func CPUCostMeasurementHandlesSecondBoundariesAndRefusesBrokenSamples() throws {
        var samples = [timespec(tv_sec: 3, tv_nsec: 999_000_000), timespec(tv_sec: 4, tv_nsec: 1_000_000)]
        let cost = try GuardCPUCostTestClock.measure({}, sample: { samples.removeFirst() })
        #expect(cost == .milliseconds(2))
        #expect(throws: GuardCPUCostTestClock.Failure.unreadableClock) {
            try GuardCPUCostTestClock.measure({}, sample: { throw GuardCPUCostTestClock.Failure.unreadableClock })
        }
        for invalid in [timespec(tv_sec: -1, tv_nsec: 0), timespec(tv_sec: 0, tv_nsec: -1),
                        timespec(tv_sec: 0, tv_nsec: 1_000_000_000)] {
            #expect(throws: GuardCPUCostTestClock.Failure.invalidSample) {
                try GuardCPUCostTestClock.measure({}, sample: { invalid })
            }
        }
        var backwards = [timespec(tv_sec: 5, tv_nsec: 0), timespec(tv_sec: 4, tv_nsec: 999_999_999)]
        #expect(throws: GuardCPUCostTestClock.Failure.backwardsClock) {
            try GuardCPUCostTestClock.measure({}, sample: { backwards.removeFirst() })
        }
    }

    @Test func matchesSpanLinesAndReportEachNameOnce() throws {
        let lines = ["sudo ls", "sudo rm -rf x"]
        let guards = try Self.semanticGuards()
        let names = guards.matches(in: lines)
        #expect(names == ["rm -rf", "sudo"])
        // A command split across lines by a continuation is seen whole as well as line by line.
        #expect(guards.matches(in: ["rm \\", "-rf /"]) == ["rm -rf"])
        #expect(guards.matches(in: ["git push \\", "--force origin main"]) == ["force push"])
        #expect(guards.matches(in: ["chmod \\", "777 x"]) == ["permissions"])
    }
}

private enum GuardCPUCostTestClock {
    enum Failure: Error, Equatable { case unreadableClock, invalidSample, backwardsClock }

    // Non-escaping synchronous operation prevents a cooperative suspension/thread change between samples.
    static func measure(_ operation: () -> Void, sample: () throws -> timespec = read) throws -> Duration {
        let start = try duration(sample())
        operation()
        let end = try duration(sample())
        guard end >= start else { throw Failure.backwardsClock }
        return end - start
    }

    private static func read() throws -> timespec {
        var sample = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &sample) == 0 else { throw Failure.unreadableClock }
        return sample
    }

    private static func duration(_ sample: timespec) throws -> Duration {
        guard sample.tv_sec >= 0, sample.tv_nsec >= 0, sample.tv_nsec < 1_000_000_000 else {
            throw Failure.invalidSample
        }
        // Duration arithmetic avoids overflowing a seconds-to-nanoseconds integer multiplication.
        return .seconds(Int64(sample.tv_sec)) + .nanoseconds(Int64(sample.tv_nsec))
    }
}
