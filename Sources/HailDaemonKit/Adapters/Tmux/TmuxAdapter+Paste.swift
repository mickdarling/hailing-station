import Foundation
import Synchronization

/// One look at a pane (#304): visible rows and cursor from one tmux invocation, so both belong to the same moment.
/// Decisions read only the text ending at the cursor, where a line editor keeps unsubmitted input; text elsewhere
/// (a transcript echoing an earlier prompt with the same ending) is not evidence either way.
struct PaneObservation: Equatable, Sendable {
    static let cursorFormat = "#{cursor_x},#{cursor_y}"

    var rows: [String]
    var cursorX: Int
    var cursorY: Int

    init(rows: [String], cursorX: Int, cursorY: Int) {
        self.rows = rows
        self.cursorX = cursorX
        self.cursorY = cursorY
    }

    /// Parses the capture followed by the cursor line; nil when the output does not end in `x,y`.
    init?(captured stdout: String) {
        var lines = stdout.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let last = lines.popLast() else { return nil }
        let parts = last.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]), x >= 0, y >= 0 else { return nil }
        while lines.count <= y { lines.append("") }
        self.init(rows: lines, cursorX: x, cursorY: y)
    }

    var isBlank: Bool { rows.allSatisfy { $0.allSatisfy(\.isWhitespace) } }

    /// What the input at the cursor shows relative to a delivered text.
    enum Input: Equatable {
        /// The tail (or a paste placeholder) ends at a cursor past column 0: drawn and pending. An Enter taken as a
        /// newline inside a TUI's input lands here too, since only whitespace follows the tail.
        case holding
        /// The tail ends right before a cursor in column 0: a terminal ended the line, or the text filled its row.
        case lineEnded
        /// Neither the tail nor a placeholder ends at the cursor.
        case clear
        /// Neither ends at the cursor as far as can be told, but the cursor row holds characters of unknown column
        /// width before the cursor, so where the cursor sits in the text is not certain: never taken as `clear`.
        case uncertain

        var isDrawn: Bool { self == .holding || self == .lineEnded }
        var mayHoldInput: Bool { self == .holding || self == .uncertain }
    }

    /// `tail` nil checks only for a paste placeholder.
    func input(_ tail: PayloadTail?) -> Input {
        let (before, certain) = scalarsBeforeCursor(atLeast: max(tail?.scalars.count ?? 0, Self.placeholderReach))
        let drawn = (tail.map { before.ends(with: $0.scalars) } ?? false) || Self.endsInPastePlaceholder(before)
        guard drawn else { return certain ? .clear : .uncertain }
        return cursorX > 0 ? .holding : .lineEnded
    }

    /// The non-whitespace scalars that end at the cursor: the cursor row up to the cursor column, preceded by as
    /// many earlier rows as it takes to hold `count` scalars (wrapping and indentation never interrupt a match).
    /// `certain` is false when the cursor row's prefix holds a character of unknown column width.
    func scalarsBeforeCursor(atLeast count: Int) -> (scalars: [Unicode.Scalar], certain: Bool) {
        guard cursorY < rows.count else { return ([], true) }
        let prefix = Self.prefix(of: rows[cursorY], columns: cursorX)
        var collected = Self.visible(prefix.text)
        var row = cursorY
        while collected.count < count, row > 0 {
            row -= 1
            collected = Self.visible(rows[row][...]) + collected
        }
        return (collected, prefix.certain)
    }

    private static func visible(_ text: Substring) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { !$0.properties.isWhitespace }
    }

    /// The part of `row` drawn left of `columns`, counting wide scalars as two columns and combining ones as none.
    /// A character whose width is not known for certain counts as one column and makes the result uncertain:
    /// with a miscount the cursor could fall anywhere, so an uncertain prefix never confirms that text left.
    static func prefix(of row: String, columns: Int) -> (text: Substring, certain: Bool) {
        var used = 0
        var certain = true
        var end = row.startIndex
        for character in row {
            let known = character.unicodeScalars.first.flatMap(columnWidth)
            certain = certain && known != nil
            let width = known ?? 1
            guard used + width <= columns else { break }
            used += width
            end = row.index(after: end)
        }
        return (row[..<end], certain)
    }

    /// Column width where it is known for certain (East Asian Width narrow or wide in every terminal), else nil.
    private static func columnWidth(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x20...0x7E, 0xA0...0x2FF, 0x370...0x52F, 0x2010...0x205E, 0x2190...0x21FF, 0x2500...0x259F,
             0x2768...0x2775: return 1
        case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F: return 0
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD: return 2
        default: return nil
        }
    }

    // MARK: Claude Code heuristic

    /// How far back a placeholder is looked for.
    static let placeholderReach = 48
    /// Claude Code collapses a long paste into `[Pasted text #N]` or `[Pasted text #N +M lines]` in its input, so
    /// the payload's own tail is never drawn. This is the one target-specific rule in the submit path: a cursor
    /// that ends in such a placeholder (whitespace removed) is treated as holding pasted text. It cannot fire in
    /// a shell or other line editor unless that text is literally typed there, and then holding is the truth.
    static func endsInPastePlaceholder(_ scalars: [Unicode.Scalar]) -> Bool {
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars.suffix(placeholderReach))
        return String(text).contains(#/\[Pastedtext#\d+(\+\d+lines?)?\]$/#)
    }
}

/// The end of a delivered text as a terminal shows it: its last non-whitespace scalars (#304).
struct PayloadTail: Equatable, Sendable {
    static let length = 32
    let scalars: [Unicode.Scalar]

    init(_ text: String) {
        scalars = Array(text.unicodeScalars.filter { !$0.properties.isWhitespace }.suffix(Self.length))
    }
}

private extension Array where Element == Unicode.Scalar {
    func ends(with suffix: [Unicode.Scalar]) -> Bool {
        !suffix.isEmpty && count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}

extension TmuxAdapter {
    /// Puts `text` into a uniquely named tmux buffer (`set-buffer`, then `set-buffer -a` per chunk, so no single
    /// argv grows with the text and nothing reaches the pane yet) and pastes it in one piece with `-p`: bracketed
    /// when the target asked for bracketed paste, plain otherwise. `-d` deletes the buffer once pasted. A failure
    /// or abandonment while filling deletes the buffer; `pasting` runs just before the paste is attempted.
    func paste(
        _ text: String, into session: Session, target: String, abandoned: DeliveryAbandonment, pasting: () -> Void
    ) async throws {
        let buffer = "hail-\(UUID().uuidString)"
        do {
            for (index, chunk) in Self.chunks(text, size: chunkSize).enumerated() {
                try abandoned.check()
                let append = index == 0 ? [] : ["-a"]
                let fill = ["set-buffer"] + append + ["-b", buffer, "--", Self.bufferArgument(chunk)]
                try await tmux(fill, failure: AdapterError.deliveryFailed)
            }
            // The identity once more right before the paste: the pre-check may have waited for pending text, and a
            // pane respawned or moved meanwhile must not receive it (threat model B3). Abandonment is checked after
            // that lookup, so a cancellation that lands during it still stops the paste.
            _ = try await verified(target, binding: session.binding)
            try abandoned.check()
            pasting()
            let paste = ["paste-buffer", "-p", "-d", "-b", buffer, "-t", session.paneID]
            try await tmux(paste, failure: AdapterError.deliveryFailed)
        } catch {
            _ = try? await runner.run(tmuxPath, Self.baseArguments(socket: socket) + ["delete-buffer", "-b", buffer])
            throw error
        }
    }

    nonisolated func observePane(_ paneID: String) async -> PaneObservation? {
        await TmuxSubmitProbe.observe(paneID, runner: runner, tmux: tmuxPath, base: Self.baseArguments(socket: socket))
    }
}

extension TmuxSubmitProbe {
    /// One look at the pane: rows and cursor from a single tmux invocation; nil when it cannot be read.
    static func observe(
        _ paneID: String, runner: any CommandRunner, tmux: String, base: [String]
    ) async -> PaneObservation? {
        let arguments = base + ["capture-pane", "-p", "-t", paneID, ";",
                                "display-message", "-p", "-t", paneID, PaneObservation.cursorFormat]
        guard let result = try? await runner.run(tmux, arguments), result.exitCode == 0 else { return nil }
        return PaneObservation(captured: result.stdout)
    }
}

/// One delivery's submit decision: the caller's cancellation and the Enter race for it under one lock.
final class DeliveryAbandonment: Sendable {
    private enum State { case pending, abandoned, committed }
    private let state = Mutex(State.pending)
    /// Abandons a delivery that has not committed; a committed one is unaffected.
    func abandon() { state.withLock { if $0 == .pending { $0 = .abandoned } } }
    func check() throws { if state.withLock({ $0 == .abandoned }) { throw CancellationError() } }
    /// True exactly once, for a delivery not yet abandoned; from then on abandonment cannot stop the Enter.
    func commit() -> Bool {
        state.withLock {
            guard $0 == .pending else { return false }
            $0 = .committed
            return true
        }
    }
}
