// The draft parser, the flush outcome types and the gated clear stay together: each is checked against the others.
// swiftlint:disable file_length
import Foundation

/// The unsent text in an agent's prompt, as `haild targets flush` reads it (#894 ask 1): the cursor row's text after the
/// prompt marker (`>` or `❯`, at column 0 or inside a `│ ` box), trailing blanks and a closing `│` removed. The text
/// is the owner's to recover, so it goes to the terminal only, never to a log, OSLog or the audit log.
public struct TmuxPromptDraft: Sendable, Equatable {
    public let text: String
    /// The cursor sits at the draft's first column with text to its right: often an agent's greyed hint, not input.
    public let cursorAtStart: Bool
    /// The row it was read from and the column where the draft starts, right after the marker and its space.
    let row: Int
    let startColumn: Int

    /// Nothing to clear: no text after the marker and nothing (not even a blank) before the cursor.
    public var isEmpty: Bool { text.isEmpty && cursorAtStart }
}

/// Why a flush sent nothing more (#894), as a log token (`rawValue`) and a plain message; neither carries pane text.
/// A refusal before the clear sent nothing; one after the `End` sent only that `End`. `unreadable`: the pane could not
/// be captured. `notAgent`: its foreground command is not in `TmuxAdapter.agentCommands`. `noMarker`: the cursor row
/// has no prompt marker. `multiLine`: the draft spans rows. `placeholder`: it holds a collapsed paste or image, whose
/// real length is not on screen. `changed`: it is no longer the draft the owner was shown.
public enum TmuxFlushRefusal: String, Error, Sendable, Equatable {
    case unreadable, notAgent = "not_agent", noMarker = "no_marker", multiLine = "multi_line", placeholder, changed

    public var message: String {
        switch self {
        case .unreadable: "the pane could not be read"
        case .notAgent: "the pane is not running Claude Code or Codex"
        case .noMarker: "the cursor row has no prompt marker (> or ❯): the pane is not at a prompt, or the draft wraps"
        case .multiLine: "the draft spans more than one line; clear it by hand"
        case .placeholder: "the draft holds a collapsed paste ([Pasted text #N]); clear it by hand"
        case .changed: "the draft changed after it was shown; run the flush again"
        }
    }

    /// The token-only log line for this refusal.
    public var logLine: String { TmuxFlushResult.logLine(cleared: 0, result: "refused", reason: rawValue) }
}

/// What a flush did: how many `BSpace` keys it sent, and what its last look at the prompt showed.
public struct TmuxFlushResult: Sendable, Equatable {
    /// What the last look showed, as a log token: `none` (`empty`), `text_left` (text before the cursor),
    /// `text_after_cursor` (only text right of it, likely the agent's hint), `blank_before_cursor` (blanks remain),
    /// `no_prompt` (no marker on the cursor row) or `unreadable`.
    public enum Remainder: String, Sendable {
        case empty = "none", textLeft = "text_left", textAfterCursor = "text_after_cursor"
        case blankBeforeCursor = "blank_before_cursor", noPrompt = "no_prompt", unreadable
    }

    public let clearedCharacters: Int
    public let remainder: Remainder
    public var isEmpty: Bool { remainder == .empty }

    /// `targets_flush cleared_chars=<n> result=empty|not_empty reason=<token>`: counts and tokens, never the words.
    public var logLine: String {
        Self.logLine(cleared: clearedCharacters, result: isEmpty ? "empty" : "not_empty", reason: remainder.rawValue)
    }

    public static func logLine(cleared: Int, result: String, reason: String) -> String {
        "targets_flush cleared_chars=\(cleared) result=\(result) reason=\(reason)"
    }

    static func remainder(of look: PaneObservation?) -> Remainder {
        guard let look else { return .unreadable }
        guard let draft = try? look.promptDraft() else { return .noPrompt }
        if draft.isEmpty { return .empty }
        if draft.cursorAtStart { return .textAfterCursor }
        return draft.text.isEmpty ? .blankBeforeCursor : .textLeft
    }
}

/// How long a flush waits for the agent to redraw its prompt after the `BSpace` keys (#894): an agent busy with a
/// turn redraws its input tens to hundreds of milliseconds late, so one look straight away can still show the draft.
/// The prompt is looked at again every `interval` until it reads empty or `limit` has been waited. `sleep` is
/// injectable, so tests wait no real time.
public struct TmuxFlushRedraw: Sendable {
    public var interval: Duration
    public var limit: Duration
    let sleep: @Sendable (Duration) async -> Void

    init(interval: Duration, limit: Duration, sleep: @escaping @Sendable (Duration) async -> Void) {
        (self.interval, self.limit, self.sleep) = (interval, limit, sleep)
    }

    public static let standard = TmuxFlushRedraw(interval: .milliseconds(100), limit: .seconds(2)) {
        try? await Task.sleep(for: $0)
    }
}

extension PaneObservation {
    static let promptMarkers: Set<Character> = [">", "❯"]
    /// The prompt draft at the cursor (#894). Refused, rather than guessed, when the cursor row has no marker at
    /// column 0 (or right after a `│ ` box edge), when a later row before the input's bottom rule is indented to the
    /// draft (a second line), or when the draft holds a paste placeholder.
    func promptDraft() throws(TmuxFlushRefusal) -> TmuxPromptDraft {
        guard cursorY < rows.count, let start = Self.draftStart(rows[cursorY]), cursorX >= start.column else {
            throw .noMarker
        }
        var text = String(rows[cursorY].dropFirst(start.characters))
        text = Self.trimmingTrailingBlanks(text)
        if text.hasSuffix("│") { text = Self.trimmingTrailingBlanks(String(text.dropLast())) }
        if rows[(cursorY + 1)...].prefix(while: { !Self.isRule($0) }).contains(where: {
            Self.indentation(of: $0).map { $0 >= start.column } ?? false
        }) {
            throw .multiLine
        }
        if text.contains(#/\[(Pasted text|Image) #\d+/#) { throw .placeholder }
        return TmuxPromptDraft(
            text: text, cursorAtStart: cursorX == start.column, row: cursorY, startColumn: start.column
        )
    }

    /// How many `BSpace` presses clear `draft` from this look, taken after the `End`: every character of the draft
    /// when the cursor is at or past its end (plus one per blank between its end and the cursor, which a capture does
    /// not show), and otherwise only the characters before the cursor. A character of unknown width counts as two
    /// columns for the blanks and the characters before the cursor, so the count never exceeds what is there.
    func backspaces(clearing draft: TmuxPromptDraft) -> Int {
        let characters = Array(draft.text)
        let widths = characters.map(Self.knownWidth)
        let narrow = draft.startColumn + widths.reduce(0) { $0 + ($1 ?? 1) }
        let wide = draft.startColumn + widths.reduce(0) { $0 + ($1 ?? 2) }
        if cursorX >= wide { return characters.count + cursorX - wide }
        if cursorX >= narrow { return characters.count }
        var (column, count) = (draft.startColumn, 0)
        for width in widths {
            guard column + (width ?? 2) <= cursorX else { break }
            column += width ?? 2
            count += 1
        }
        return count
    }

    /// The draft's start for `>`/`❯` at column 0 or after `│ `, then a space or the row's end: its column (the marker
    /// and one space; a capture drops a trailing space) and the characters before it on the row. A continuation row of
    /// a multi-line draft is indented, so it never matches.
    private static func draftStart(_ row: String) -> (column: Int, characters: Int)? {
        let characters = Array(row)
        let marker = characters.starts(with: ["│", " "]) ? 2 : 0
        guard characters.count > marker, promptMarkers.contains(characters[marker]) else { return nil }
        guard characters.count == marker + 1 || [" ", "\u{00A0}"].contains(characters[marker + 1]) else { return nil }
        return (marker + 2, min(characters.count, marker + 2))
    }
    /// The column of a row's first visible character, a `│` box edge read as a blank; nil for a blank row.
    private static func indentation(of row: String) -> Int? {
        var characters = Array(row)
        if characters.first == "│" { characters[0] = " " }
        while let last = characters.last, last.isWhitespace || last == "│" { characters.removeLast() }
        return characters.firstIndex { !$0.isWhitespace }
    }
    /// A rule or box border row (`────`, `╰──╯`): the input's bottom edge, below which an agent draws its hints. A
    /// row of `│` edges alone is an empty line inside a box, not its border.
    private static func isRule(_ row: String) -> Bool {
        let visible = row.unicodeScalars.filter { !$0.properties.isWhitespace }
        return visible.contains { $0 != "│" }
            && visible.allSatisfy { (0x2500...0x257F).contains($0.value) || $0 == "-" }
    }
    private static func trimmingTrailingBlanks(_ text: String) -> String {
        String(text.reversed().drop(while: \.isWhitespace).reversed())
    }
    /// A character's column width where `prefix(of:columns:)` knows it for certain (0, 1 or 2), else nil.
    private static func knownWidth(_ character: Character) -> Int? {
        (0...2).first { prefix(of: String(character), columns: $0, unknownWidth: 3).count == 1 }
    }
}

/// The keys a flush can send: there is no case for `Escape` or `C-c`, which would interrupt a running agent turn.
enum TmuxFlushKey: String {
    case end = "End"
    case backspace = "BSpace"
}

extension TmuxAdapter {
    /// The draft in `target`'s prompt, read only (#894). Refused for a pane that is not an agent.
    public func promptDraft(_ target: String, binding: String?) async throws -> TmuxPromptDraft {
        let session = try await verified(target, binding: binding)
        return try await readDraft(session.paneID)
    }

    /// Clears `draft` from `target`'s prompt, if it is still the draft there (#894): `End`, a fresh look that must
    /// show the same draft, then exactly one `BSpace` per character before the cursor, each step under the tmux
    /// server's agent check (`isAgentFormat`, as for the Enter after a framed paste) and after the binding is checked
    /// again. Never `Escape` or `C-c`. Looks then wait for the redraw (`redraw`) and report whether the prompt reads
    /// empty. This adapter's taint (a `haild` process's own memory) is untouched: a flush from the CLI cannot clear a
    /// running daemon's taint.
    public func flushPrompt(
        _ target: String, binding: String?, expecting draft: TmuxPromptDraft, redraw: TmuxFlushRedraw = .standard
    ) async throws -> TmuxFlushResult {
        let session = try await verified(target, binding: binding)
        let pane = session.paneID
        let current = try await readDraft(pane)
        guard current.text == draft.text else { throw TmuxFlushRefusal.changed }
        _ = try await verified(target, binding: session.binding)
        try await sendToAgent(pane, [.end])
        guard let ended = await observePane(pane) else { throw TmuxFlushRefusal.unreadable }
        // The live input is the cursor row (a transcript row above may also start with a marker); it must not move.
        let moved = try ended.promptDraft()
        guard moved.text == draft.text, moved.row == current.row else { throw TmuxFlushRefusal.changed }
        let count = ended.backspaces(clearing: moved)
        guard count > 0 else {
            return TmuxFlushResult(clearedCharacters: 0, remainder: TmuxFlushResult.remainder(of: ended))
        }
        _ = try await verified(target, binding: session.binding)
        try await sendToAgent(pane, Array(repeating: .backspace, count: count))
        // Looks only, until the redraw shows an empty prompt or the limit passes; nothing more is sent.
        var remainder = TmuxFlushResult.remainder(of: await observePane(pane))
        var waited = Duration.zero
        while remainder != .empty, waited < redraw.limit {
            await redraw.sleep(redraw.interval)
            waited += redraw.interval
            remainder = TmuxFlushResult.remainder(of: await observePane(pane))
        }
        return TmuxFlushResult(clearedCharacters: count, remainder: remainder)
    }

    private func readDraft(_ pane: String) async throws -> TmuxPromptDraft {
        let probe = ["display-message", "-p", "-t", pane, Self.isAgentFormat]
        let agent = try await tmux(probe, failure: AdapterError.captureFailed)
        guard agent.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw TmuxFlushRefusal.notAgent
        }
        guard let look = await observePane(pane) else { throw TmuxFlushRefusal.unreadable }
        return try look.promptDraft()
    }

    /// `keys` to `pane` in one `send-keys`, only while its foreground command is an agent: the tmux server checks and
    /// sends in one command, as `pressEnter` does after a framed paste, so nothing reaches a shell that took its place.
    private func sendToAgent(_ pane: String, _ keys: [TmuxFlushKey]) async throws {
        guard pane.hasPrefix("%"), pane.dropFirst().allSatisfy(\.isNumber), !keys.isEmpty else {
            throw AdapterError.deliveryFailed("unexpected tmux pane name")
        }
        let refused = "hail-flush-not-agent"
        let send = (["send-keys", "-t", pane] + keys.map(\.rawValue)).joined(separator: " ")
        let result = try await tmux(
            ["if-shell", "-F", "-t", pane, Self.isAgentFormat, send, "display-message -p \(refused)"],
            failure: AdapterError.deliveryFailed
        )
        if result.stdout.contains(refused) { throw TmuxFlushRefusal.notAgent }
    }
}
