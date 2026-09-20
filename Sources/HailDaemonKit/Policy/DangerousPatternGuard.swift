import Foundation

/// One guard rule: a name the terminal can speak and a case-insensitive regular expression (#41 item 3).
public struct GuardPattern: Codable, Sendable, Equatable {
    public var name: String
    public var regex: String

    public init(name: String, regex: String) {
        self.name = name
        self.regex = regex
    }
}

/// A rule that does not compile, reported by name so it can be fixed at the keyboard.
public struct InvalidGuardPattern: Error, Equatable, Sendable {
    public var name: String
}

/// The guard rules compiled once. Built from a `Policy` at construction, so an invalid rule is refused
/// there and never at delivery time. `NSRegularExpression` is immutable and thread-safe, and its `\b` is
/// the simple word boundary the rules are written for.
public struct CompiledGuards: Sendable {
    private let rules: [(name: String, regex: NSRegularExpression)]
    private let matchBudget: Duration

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
        let candidates = lines.count > 1 ? lines + [lines.joined(separator: " ")] : lines
        let clock = ContinuousClock()
        return rules.compactMap { rule in
            let deadline = clock.now + matchBudget
            return candidates.contains { line in
                boundedMatch(rule.regex, in: line, clock: clock, deadline: deadline)
            } ? rule.name : nil
        }
    }

    /// ICU progress callbacks bound custom expressions; exceeding the budget is a guard hit, never a bypass.
    private func boundedMatch(
        _ regex: NSRegularExpression, in line: String, clock: ContinuousClock, deadline: ContinuousClock.Instant
    ) -> Bool {
        var hit = false
        let range = NSRange(line.startIndex..., in: line)
        regex.enumerateMatches(in: line, options: .reportProgress, range: range) { result, _, stop in
            if result != nil || clock.now >= deadline {
                hit = true
                stop.pointee = true
            }
        }
        return hit
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
        patterns.compactMap { pattern in
            guard let compiled = try? CompiledGuards([pattern]) else { return "\(pattern.name) (invalid rule)" }
            return compiled.matches(in: lines).first
        }
    }
}
