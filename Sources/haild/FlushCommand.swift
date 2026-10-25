import Darwin
import Foundation
import HailDaemonKit

/// `haild targets flush <target-id> [--yes]` (#894 ask 1): clears unsent text from a tmux agent's prompt, so a
/// delivery refused because text is pending there can go ahead. Gated as `escape` (allowed, bound, not rebound, not
/// locked, no lockdown). The draft is printed alone on standard output, so the owner can recover it
/// (`haild targets flush tmux:work > draft.txt`); every other line goes to standard error, and the
/// `targets_flush ...` line there carries counts and reason tokens only, never the words.
/// Exit codes: 0 cleared or already empty, 4 refused (nothing cleared), 6 text still shown afterwards, 8 confirmation
/// needed (not a terminal and no `--yes`) or cancelled; the policy's own codes as for `send`.
enum FlushCommand {
    static let taintHint = "a flush cannot clear a running haild's own record of a tainted pane: if haild still refuses"
        + " this target as tainted, restart haild (scripts/host.sh restart)"

    static func run(_ host: HailHost, _ arguments: ArraySlice<String>) async throws {
        let yes = arguments.contains("--yes")
        let names = arguments.filter { $0 != "--yes" }
        guard names.count == 1, let id = names.first, !id.hasPrefix("-"), arguments.count == (yes ? 2 : 1) else {
            usage()
        }
        let draft = try await refusing { try await host.promptDraft(id) }
        guard !draft.isEmpty else {
            note(TmuxFlushResult.logLine(cleared: 0, result: "empty", reason: "nothing_to_clear"))
            note("\(id): the prompt is already empty; nothing was sent")
            return
        }
        let count = draft.text.count
        note("\(id): prompt draft, \(count) character\(count == 1 ? "" : "s"), on standard output:")
        FileHandle.standardOutput.write(Data((draft.text + "\n").utf8))
        if draft.cursorAtStart {
            note("the cursor is at the start of this text: if it is the agent's greyed hint, nothing will be cleared")
        }
        if !yes { confirm() }
        let result = try await refusing { try await host.flushPrompt(id, expecting: draft) }
        note(result.logLine)
        let keys = "End and \(result.clearedCharacters) BSpace"
        if result.isEmpty {
            note("\(id): sent \(keys); the prompt is now empty")
        } else if result.textAfterCursor {
            note("\(id): sent \(keys); nothing is left before the cursor, but text still shows after it"
                 + " (likely the agent's hint); check the pane")
        } else {
            note("\(id): sent \(keys); the prompt still shows text; check the pane and clear it by hand")
        }
        note(taintHint)
        if !result.isEmpty { exit(6) }
    }

    /// A terminal must answer `flush`; anything else, or no terminal, sends nothing. Scripts pass `--yes`.
    private static func confirm() {
        guard isatty(STDIN_FILENO) == 1 else {
            note(TmuxFlushResult.logLine(cleared: 0, result: "refused", reason: "confirmation_needed"))
            fail("confirmation needed; run from a terminal, or pass --yes. Nothing was sent", code: 8)
        }
        standardError.write(Data("type flush to clear it, anything else to cancel: ".utf8))
        guard readLine()?.trimmingCharacters(in: .whitespaces) == "flush" else {
            note(TmuxFlushResult.logLine(cleared: 0, result: "refused", reason: "cancelled"))
            fail("cancelled; nothing was sent", code: 8)
        }
    }

    /// A flush refusal is reported by its message and token, and nothing was cleared; other errors reach `main`.
    private static func refusing<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let refusal as TmuxFlushRefusal {
            note(refusal.logLine)
            fail("refused: \(refusal.message); nothing was cleared", code: 4)
        }
    }
}
