import Foundation

enum TmuxDialogState: Sendable, Equatable {
    case clear
    case dialog(kind: TmuxDialogKind, title: String)
    case unknown
}

enum TmuxDialogKind: String, Sendable {
    case computerUsePermissions, computerUseAppApproval, toolPermission, modalFooter

    /// Fixed, bounded display titles; no pane text crosses the refusal boundary.
    var title: String {
        switch self {
        case .computerUsePermissions: "Computer Use needs macOS permissions"
        case .computerUseAppApproval: "Computer Use wants to control these apps"
        case .toolPermission: "a tool permission dialog"
        case .modalFooter: "a dialog"
        }
    }
}

extension TmuxAdapter {
    // Verified against Claude Code 2.1.319; titles and recognised dialog shapes may drift.
    private static let knownDialogs: [TmuxDialogKind] = [.computerUsePermissions, .computerUseAppApproval]

    /// Visible rows only. Every returned title is fixed here, never taken from the pane.
    static func classifyDialog(
        visibleScreen: String, cursorRow: Int? = nil, excludingPayload: String? = nil
    ) -> TmuxDialogState {
        let rows = visibleScreen.components(separatedBy: "\n").map(stripBorders)
        var excluded: Set<Int> = []
        if let excludingPayload {
            guard let cursorRow, rows.indices.contains(cursorRow) else { return .unknown }
            if let start = (0...cursorRow).last(where: { rows[$0].hasPrefix(">") }) {
                let payload = normalizedWhitespace(excludingPayload)
                for index in start...cursorRow {
                    let row = rows[index]
                    let text = normalizedWhitespace(row.hasPrefix("> ") ? String(row.dropFirst(2)) : row)
                    if !text.isEmpty, payload.contains(text) { excluded.insert(index) }
                }
            }
        }
        let lines = rows.enumerated().compactMap { index, row in
            excluded.contains(index) || row.isEmpty ? nil : row
        }
        for kind in knownDialogs where containsTitle(kind.title, in: lines) {
            return .dialog(kind: kind, title: kind.title)
        }
        let bottom = lines.suffix(12)
        let question = bottom.contains { $0.range(of: #"(?i)^Do you want to "#, options: .regularExpression) != nil }
        let option = bottom.contains { $0.range(of: #"(?i)^(❯\s*)?1\.\s*Yes"#, options: .regularExpression) != nil }
        if question && option {
            return .dialog(kind: .toolPermission, title: TmuxDialogKind.toolPermission.title)
        }
        let footer = bottom.contains {
            $0.range(of: #"(?i)^(?:.*\s)?esc to cancel$"#, options: .regularExpression) != nil
        }
        if footer {
            return .dialog(kind: .modalFooter, title: TmuxDialogKind.modalFooter.title)
        }
        return .clear
    }

    private static func stripBorders(_ line: String) -> String {
        let scalars = line.unicodeScalars.filter { !(0x2500...0x259F).contains($0.value) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Also accepts a wrapped title with decoration; the entire trimmed candidate must equal the fixed title.
    private static func containsTitle(_ title: String, in lines: [String]) -> Bool {
        for start in lines.indices {
            var candidate = lines[start].trimmingCharacters(in: .alphanumerics.inverted)
            var end = start
            while candidate.count < title.count, end + 1 < lines.count {
                end += 1
                candidate.append(" " + lines[end].trimmingCharacters(in: .alphanumerics.inverted))
            }
            if candidate == title { return true }
        }
        return false
    }

    /// Visible rows and cursor from one invocation, without scrollback.
    func inspectDialog(_ session: Session, excludingPayload: String? = nil) async -> TmuxDialogState {
        let arguments = Self.baseArguments(socket: socket) + [
            "capture-pane", "-p", "-t", session.paneID, ";",
            "display-message", "-p", "-t", session.paneID, "#{cursor_x},#{cursor_y}"
        ]
        guard let result = try? await runner.run(tmuxPath, arguments), result.exitCode == 0 else { return .unknown }
        var rows = result.stdout.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        guard let metadata = rows.popLast()?.split(separator: ",", omittingEmptySubsequences: false),
              (2...3).contains(metadata.count), Int(metadata[0]) != nil, let cursor = Int(metadata[1]),
              rows.indices.contains(cursor) else { return .unknown }
        return Self.classifyDialog(
            visibleScreen: rows.joined(separator: "\n"), cursorRow: cursor, excludingPayload: excludingPayload
        )
    }

    // Input runs in a separate tmux command; a dialog appearing between commands is not caught.
    // #1172 tracks composing the check and input into the same command.
    func requireClearDialog(_ session: Session, excludingPayload: String? = nil) async throws {
        switch await inspectDialog(session, excludingPayload: excludingPayload) {
        case .clear: return
        case .dialog(_, let title): throw AdapterError.deliveryFailed("target is blocked by \(title)")
        case .unknown: throw AdapterError.deliveryFailed("target dialog state could not be inspected")
        }
    }
}
