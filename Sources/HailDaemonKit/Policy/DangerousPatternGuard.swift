import Darwin
import Foundation

/// Injectable wall and thread CPU clocks (#208, #1120). Matching is synchronous: CPU readings stay on
/// one thread. The legacy wall-only test initializer freezes CPU time; production binds neither clock.
struct GuardBudgetClock: Sendable {
    @TaskLocal static var current = GuardBudgetClock(now: { ContinuousClock.now }, cpuNow: threadCPUTime)
    let now: @Sendable () -> ContinuousClock.Instant
    let cpuNow: @Sendable () -> Duration?

    init(_ now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.init(now: now, cpuNow: { .zero })
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant, cpuNow: @escaping @Sendable () -> Duration?) {
        self.now = now
        self.cpuNow = cpuNow
    }

    static func threadCPUTime() -> Duration? {
        var sample = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &sample) == 0 else { return nil }
        return .seconds(sample.tv_sec) + .nanoseconds(sample.tv_nsec)
    }
}

/// The guard rules compiled once. Built from a `Policy` at construction, so an invalid rule is refused
/// there and never at delivery time. `NSRegularExpression` is immutable and thread-safe, and its `\b` is
/// the simple word boundary the rules are written for.
/// Each rule has a 20 ms thread CPU budget (#1120) and a 1 s wall cap: scheduling pauses get 50 times
/// the CPU allowance, while stalled work remains bounded at ICU progress callbacks and scan boundaries.
/// Either expiry (or an unreadable CPU clock) is a timeout and still fails closed (#208). The target-block
/// path remains unbudgeted (#658). These are cooperative limits, not an interrupt of ICU between callbacks.
public struct CompiledGuards: Sendable {
    private let rules: [(name: String, regex: NSRegularExpression)]
    private let matchBudget: Duration
    static let wallClockCap: Duration = .seconds(1)

    public init(_ patterns: [GuardPattern], matchBudget: Duration = .milliseconds(20)) throws {
        self.matchBudget = matchBudget
        rules = try patterns.map { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive]) else {
                throw InvalidGuardPattern(name: pattern.name)
            }
            return (pattern.name, regex)
        }
    }

    /// Names of every rule that matches any line, or the lines joined by a space, in rule order, each
    /// once. The joined form catches a command split across lines (a trailing backslash continuation
    /// under a split policy would otherwise put `rm \` and `-rf /` on different Enters).
    public func matches(in lines: [String]) -> [String] {
        hits(in: lines).map(\.name)
    }

    /// Pasted text's screening (#608), never a gate: the rules that match, and the rules that ran out of budget
    /// before deciding (`unchecked`), so the note can say the paste was not fully checked rather than look clean.
    func flags(in lines: [String]) -> (matched: [String], unchecked: [String]) {
        let results = hits(in: lines)
        return (results.filter { $0.outcome == .match }.map(\.name),
                results.filter { $0.outcome == .timeout }.map(\.name))
    }

    enum Outcome { case match, timeout, none }

    /// Positive per-rule evidence in rule order, from one scan. Both outcomes require confirmation.
    public func hits(in lines: [String]) -> [GuardHit] {
        let candidates = lines.count > 1 ? lines + [lines.joined(separator: " ")] : lines
        guard !candidates.isEmpty else { return [] }
        let clock = GuardBudgetClock.current
        return rules.compactMap { rule in
            let wallDeadline = clock.now() + Self.wallClockCap
            guard let start = clock.cpuNow() else { return GuardHit(name: rule.name, outcome: .timeout) }
            let expired = { @Sendable in
                guard let cpu = clock.cpuNow() else { return true }
                return cpu - start >= matchBudget || clock.now() >= wallDeadline
            }
            for line in candidates {
                switch boundedMatch(rule.regex, in: line, expired: expired) {
                case .match: return GuardHit(name: rule.name, outcome: .match)
                case .timeout: return GuardHit(name: rule.name, outcome: .timeout)
                case .none: continue
                }
            }
            return nil
        }
    }

    /// Rule-order names with no match budget (#658). File-private: its only caller is
    /// `DangerousPatternGuard.targetBlockMatches(target:)`, whose input is host-built and length-capped.
    fileprivate func unbudgetedMatches(in line: String) -> [String] {
        rules.compactMap { rule in
            rule.regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil ? rule.name : nil
        }
    }

    /// ICU progress callbacks bound custom expressions; for the guard a timeout counts as a hit, never a bypass.
    private func boundedMatch(
        _ regex: NSRegularExpression, in line: String, expired: @Sendable () -> Bool
    ) -> Outcome {
        if expired() { return .timeout }
        var outcome = Outcome.none
        let range = NSRange(line.startIndex..., in: line)
        regex.enumerateMatches(in: line, options: .reportProgress, range: range) { result, _, stop in
            if expired() {
                outcome = .timeout
                stop.pointee = true
            } else if result != nil {
                outcome = .match
                stop.pointee = true
            }
        }
        return expired() ? .timeout : outcome
    }
}

/// Heuristic escalation of an `open` or `confirm` target's utterance (#41 item 3): the names of the
/// rules that fired are spoken in the read-back and written to the audit record. The list catches the
/// destructive commands a misheard or ambient utterance can produce; it is not adversarial (quoting,
/// escaping, and natural language to an agent evade it) and is never the only control: the allow list,
/// the tier, the binding, and the sanitizer stand regardless.
///
/// Every multi-part rule is anchored at `^` with lookaheads, and a flag cluster is consumed possessively
/// after a lookahead asserts its letter (`-(?=[a-z]*r)[a-z]*+\b`), so each part scans the line once; a
/// bare command word followed by `.*`, or a backtracking `[a-z]*r[a-z]*`, is quadratic on a long line and
/// was measured at seconds per utterance.
public enum DangerousPatternGuard {
    public static let defaults: [GuardPattern] = [
        // Forced recursive removal is always guarded; recursive removal without force is guarded at root.
        GuardPattern(
            name: "rm -rf",
            regex: #"^(?=.*\brm\b)(?=.*\s(-(?=[a-z]*r)[a-z]*+|--recursive)\b)"#
                + #"(?=.*(\s(-(?=[a-z]*f)[a-z]*+|--force)\b|\s/(\s|$)))"#
        ),
        GuardPattern(name: "sudo", regex: #"\b(sudo|doas|pkexec|su)\b"#),
        GuardPattern(
            name: "force push",
            regex: #"^(?=.*\bpush\b)(?=.*(--force\b|--mirror\b|\s-(?=[a-z]*f)[a-z]*+\b|\s\+\S))"#
        ),
        GuardPattern(name: "git reset --hard", regex: #"^(?=.*\breset\b)(?=.*--hard\b)"#),
        GuardPattern(name: "git clean", regex: #"^(?=.*\bgit\b)(?=.*\bclean\b)"#),
        GuardPattern(
            name: "destructive git",
            regex: #"\b(stash\s+(drop|clear)|checkout\s+(--\s|\.|-[a-z]*f)|restore\s+(--\s+)?\.)"#
                + #"|^(?=.*\bgit\b)(?=.*\brestore\b)"#
        ),
        GuardPattern(
            name: "branch delete",
            regex: #"^(?=.*\bbranch\b)(?=.*(\s-(?=[a-z]*d)[a-z]*+\b|--delete))"#
                + #"|^(?=.*\bpush\b)(?=.*(--delete\b|--prune\b|\s-d\b|\s:\S))"#
        ),
        GuardPattern(name: "delete", regex: #"\b(delete|drop\s+(table|database|schema)|dropdb|truncate)\b"#),
        GuardPattern(
            name: "disk write",
            regex: #"\b(mkfs\b|wipefs\b|diskutil\s+(erase\w*|secureerase|zerodisk|reformat)\b)"#
                + #"|^(?=.*\bdd\b)(?=.*\b(if|of)=)|>\s*/dev/(disk|rdisk|sd|nvme)"#
        ),
        GuardPattern(
            name: "permissions",
            regex: #"^(?=.*\bchmod\b)(?=.*(\b[0-7]{0,3}([2367][0-7]|[2367])\b|\s[augo]*[+=][rwxst]*w))"#
        ),
        GuardPattern(
            name: "shell",
            regex: #"\|\s*(sudo\s+)?(/(usr/)?bin/)?(ba|z|da)?sh\b|\b(ba|z|da)?sh\s+-[a-z]*c\b"#
        ),
        GuardPattern(name: "fork bomb", regex: #":\(\)\s*\{"#),
        GuardPattern(
            name: "credential",
            regex: #"(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|sk-[a-z0-9_-]{20,}"#
                + #"|-----BEGIN|password\W{0,3}[=:]|secret\s*[=:]|secret_access_key|api[_-]?key\s*[=:])"#
        )
    ]

    /// Convenience for tests and tools: compiles, then matches. A rule that does not compile counts as a
    /// hit under its own name, so a broken rule fails closed rather than silently disappearing.
    public static func matches(in lines: [String], patterns: [GuardPattern]) -> [String] {
        compiledEach(patterns) { $0.matches(in: lines) }
    }

    /// The longest reply block `targetBlockMatches` evaluates; anything longer is a hit (#658, defence in depth).
    static let maxTargetBlockBytes = 512

    /// The default rules hit by the reply block built for `target`, matched without the time budget (#658). The block
    /// is fixed host text around an id the caller has already allowlisted (at most 96 characters), so an expired
    /// budget there means the scheduler stalled, not that a rule matched. A block over `maxTargetBlockBytes` is a
    /// hit, as is an invalid rule. Delivered text never comes here: it keeps the budget and #208's timeout rule.
    static func targetBlockMatches(target: String) -> [String] {
        let block = RightyoInputEvent.replyBlock(target: target)
        guard block.utf8.count <= maxTargetBlockBytes else { return ["target block too long"] }
        return compiledEach(defaults) { $0.unbudgetedMatches(in: block) }
    }

    private static func compiledEach(_ patterns: [GuardPattern],
                                     _ match: (CompiledGuards) -> [String]) -> [String] {
        patterns.compactMap { pattern in
            guard let compiled = try? CompiledGuards([pattern]) else { return "\(pattern.name) (invalid rule)" }
            return match(compiled).first
        }
    }
}
