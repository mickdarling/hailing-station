import Foundation
import Synchronization

/// One look at a pane (#304), from one tmux invocation. Decisions read only the text ending at the cursor, where a
/// line editor keeps unsubmitted input; text elsewhere (a transcript echoing an earlier prompt) is not evidence.
struct PaneObservation: Equatable, Sendable {
    static let cursorFormat = "#{cursor_x},#{cursor_y},#{pane_width}"
    var rows: [String]
    var cursorX: Int
    var cursorY: Int
    /// The pane's width in columns, when tmux reported it.
    var width: Int?

    var isBlank: Bool { rows.allSatisfy { $0.allSatisfy(\.isWhitespace) } }

    /// What the input at the cursor shows relative to a delivered text.
    enum Input: Equatable {
        /// The tail (or a paste placeholder) ends at a cursor past column 0 (also after an Enter taken as a newline).
        case holding
        /// The tail ends right before a cursor in column 0: a terminal ended the line, or the text filled its row.
        case lineEnded
        /// Neither the tail nor a placeholder ends at the cursor, under any reading of the cursor row.
        case clear

        var isDrawn: Bool { self == .holding || self == .lineEnded }
    }

    /// Whether text is pending at the cursor (#304): held there, or ended by a column-0 cursor right after a row
    /// that is full width (the text wrapped or exactly filled it). A shorter row before a column-0 cursor is a
    /// completed line, as a shell or `cat` leaves after taking an Enter.
    func pending(_ tail: PayloadTail?) -> Bool {
        let input = input(tail)
        guard input == .lineEnded, let width, cursorY > 0 else { return input == .holding }
        return [1, 2].contains { unknown in
            rows[cursorY - 1].reduce(0) { $0 + ($1.unicodeScalars.first.flatMap(Self.columnWidth) ?? unknown) } >= width
        }
    }

    /// `tail` nil checks only for a paste placeholder. A character of unknown column width on the cursor row (an
    /// arrow or emoji in a shell prompt, say) is read both as one column and as two: the text counts as drawn when
    /// it ends at the cursor under either reading, so a miscount can never hide pending text, and as clear only
    /// when it ends there under neither.
    func input(_ tail: PayloadTail?) -> Input {
        let count = max(tail?.scalars.count ?? 0, Self.placeholderReach)
        let drawn = [1, 2].contains { unknownWidth in
            let before = scalarsBeforeCursor(atLeast: count, unknownWidth: unknownWidth)
            return (tail.map { before.ends(with: $0.scalars) } ?? false) || Self.endsInPastePlaceholder(before)
        }
        guard drawn else { return .clear }
        return cursorX > 0 ? .holding : .lineEnded
    }

    /// The non-whitespace scalars that end at the cursor: the cursor row up to the cursor column, preceded by as
    /// many earlier rows as it takes to hold `count` scalars (wrapping and indentation never interrupt a match).
    /// A character of unknown width on the cursor row counts as `unknownWidth` columns.
    func scalarsBeforeCursor(atLeast count: Int, unknownWidth: Int) -> [Unicode.Scalar] {
        guard cursorY < rows.count else { return [] }
        var collected = Self.visible(Self.prefix(of: rows[cursorY], columns: cursorX, unknownWidth: unknownWidth))
        var row = cursorY
        while collected.count < count, row > 0 {
            row -= 1
            collected = Self.visible(rows[row][...]) + collected
        }
        return collected
    }

    private static func visible(_ text: Substring) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { !$0.properties.isWhitespace }
    }

    /// The part of `row` drawn left of `columns`, counting wide scalars as two columns, combining ones as none, and
    /// a character whose width is not known for certain as `unknownWidth`.
    static func prefix(of row: String, columns: Int, unknownWidth: Int = 1) -> Substring {
        var used = 0
        var end = row.startIndex
        for character in row {
            let width = character.unicodeScalars.first.flatMap(columnWidth) ?? unknownWidth
            guard used + width <= columns else { break }
            used += width
            end = row.index(after: end)
        }
        return row[..<end]
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

extension PaneObservation {
    /// Parses the capture followed by the `x,y[,width]` line; nil when the output does not end in one.
    init?(captured stdout: String) {
        var lines = stdout.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let parts = (lines.popLast() ?? "").split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), let x = parts[0], let y = parts[1], x >= 0, y >= 0 else { return nil }
        while lines.count <= y { lines.append("") }
        self.init(rows: lines, cursorX: x, cursorY: y, width: parts.count == 3 ? parts[2] : nil)
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
    /// when the target asked for it. `-d` deletes the buffer once pasted, and a failure, refusal or abandonment
    /// before then deletes it. `pasting` runs just before the paste; returns the look taken right before it.
    func paste(
        _ text: String, into session: Session, target: String, abandoned: DeliveryAbandonment, pasting: () -> Void
    ) async throws -> PaneObservation? {
        let pending = [PayloadTail(text), lastTails[session.paneID]]
        let buffer = "hail-\(UUID().uuidString)"
        do {
            for (index, chunk) in Self.chunks(text, size: chunkSize).enumerated() {
                try abandoned.check()
                let append = index == 0 ? [] : ["-a"]
                let fill = ["set-buffer"] + append + ["-b", buffer, "--", Self.bufferArgument(chunk)]
                try await tmux(fill, failure: AdapterError.deliveryFailed)
            }
            // Right before the paste: the identity (threat model B3), then the input (text that appeared at the cursor
            // while the buffer filled), then abandonment, so a cancellation during either lookup stops the paste.
            _ = try await verified(target, binding: session.binding)
            let fresh = await observePane(session.paneID)
            if let fresh, await pendingIndex(fresh, pending, in: session.paneID) != nil {
                throw AdapterError.deliveryFailed("unsubmitted text appeared in the input of pane \(target)")
            }
            try abandoned.check()
            pasting()
            let paste = ["paste-buffer", "-p", "-d", "-b", buffer, "-t", session.paneID]
            try await tmux(paste, failure: AdapterError.deliveryFailed)
            return fresh
        } catch {
            _ = try? await runner.run(tmuxPath, Self.baseArguments(socket: socket) + ["delete-buffer", "-b", buffer])
            throw error
        }
    }

    /// One look at the pane: rows, cursor and width from a single tmux invocation; nil when it cannot be read.
    nonisolated func observePane(_ paneID: String) async -> PaneObservation? {
        let look = ["capture-pane", "-p", "-t", paneID, ";", "display-message", "-p", "-t", paneID,
                    PaneObservation.cursorFormat]
        guard let result = try? await runner.run(tmuxPath, Self.baseArguments(socket: socket) + look),
              result.exitCode == 0 else { return nil }
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
