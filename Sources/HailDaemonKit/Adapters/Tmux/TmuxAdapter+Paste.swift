import Foundation

/// One look at a pane for the submit decision (#304): the visible rows and the cursor, read by one tmux
/// invocation (`capture-pane -p ; display-message -p <cursorFormat>`) so the two belong to the same moment.
///
/// Delivery decisions read only the text that ends at the cursor, because that is where a line editor keeps
/// what has been typed and not yet submitted. Text elsewhere on the screen, such as a TUI's transcript echoing
/// an earlier prompt with the same ending, is not evidence either way.
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
        /// The text's tail (or a paste placeholder) ends at the cursor, and the cursor is past column 0: the
        /// text is drawn and still pending. A TUI that took an Enter as a newline inside its input also lands
        /// here, since only whitespace follows the tail.
        case holding
        /// The tail ends right before a cursor in column 0: a terminal ended the line (a shell or `cat` that
        /// took the Enter), or the text filled its last row exactly and the cursor wrapped.
        case lineEnded
        /// Neither the tail nor a placeholder ends at the cursor.
        case clear
    }

    /// `tail` nil checks only for a paste placeholder.
    func input(_ tail: PayloadTail?) -> Input {
        let before = scalarsBeforeCursor(atLeast: max(tail?.scalars.count ?? 0, Self.placeholderReach))
        let drawn = (tail.map { before.ends(with: $0.scalars) } ?? false) || Self.endsInPastePlaceholder(before)
        guard drawn else { return .clear }
        return cursorX > 0 ? .holding : .lineEnded
    }

    /// The non-whitespace scalars that end at the cursor: the cursor row up to the cursor column, preceded by as
    /// many earlier rows as it takes to hold `count` scalars (wrapping and indentation never interrupt a match).
    func scalarsBeforeCursor(atLeast count: Int) -> [Unicode.Scalar] {
        guard cursorY < rows.count else { return [] }
        var collected = Self.visible(Self.prefix(of: rows[cursorY], columns: cursorX))
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

    /// The part of `row` drawn left of `columns`, counting wide scalars as two columns and combining ones as none.
    /// The count is approximate for exotic text; a miscount only makes a match fail, never succeed wrongly.
    static func prefix(of row: String, columns: Int) -> Substring {
        var used = 0
        var end = row.startIndex
        for character in row {
            let width = character.unicodeScalars.first.map(columnWidth) ?? 1
            guard used + width <= columns else { break }
            used += width
            end = row.index(after: end)
        }
        return row[..<end]
    }

    private static func columnWidth(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F: return 0
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD: return 2
        default: return 1
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
    func paste(_ text: String, into paneID: String, abandoned: DeliveryAbandonment, pasting: () -> Void) async throws {
        let buffer = "hail-\(UUID().uuidString)"
        do {
            for (index, chunk) in Self.chunks(text, size: chunkSize).enumerated() {
                try abandoned.check()
                let append = index == 0 ? [] : ["-a"]
                let fill = ["set-buffer"] + append + ["-b", buffer, "--", chunk]
                try await tmux(fill, failure: AdapterError.deliveryFailed)
            }
            try abandoned.check()
            pasting()
            let paste = ["paste-buffer", "-p", "-d", "-b", buffer, "-t", paneID]
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
