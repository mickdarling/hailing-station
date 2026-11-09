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

/// The detector supplies only the cause; delivery accounting supplies effects at the failure boundary.
struct TmuxDialogVeto: Error, Sendable {
    let cause: DialogBlock.Cause
}

extension TmuxAdapter {
    // Verified against Claude Code 2.1.319; titles and recognised dialog shapes may drift.
    private static let knownDialogs: [TmuxDialogKind] = [.computerUsePermissions, .computerUseAppApproval]

    /// Visible rows only. Every returned title is fixed here, never taken from the pane.
    static func classifyDialog(visibleScreen: String) -> TmuxDialogState {
        let lines = visibleScreen.components(separatedBy: "\n").map(stripBorders).filter { !$0.isEmpty }
        for kind in knownDialogs where containsTitle(kind.title, in: lines) {
            return .dialog(kind: kind, title: kind.title)
        }
        let bottom = lines.suffix(12)
        let question = bottom.contains {
            $0.range(of: #"(?i)^(❯\s*)?Do you want to "#, options: .regularExpression) != nil
        }
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

    /// Visible screen only, without scrollback or cursor metadata.
    func inspectDialog(_ session: Session) async -> TmuxDialogState {
        let arguments = Self.baseArguments(socket: socket) + ["capture-pane", "-p", "-t", session.paneID]
        guard let result = try? await runner.run(tmuxPath, arguments), result.exitCode == 0,
              !result.stdout.isEmpty else { return .unknown }
        return Self.classifyDialog(visibleScreen: result.stdout)
    }

    // Input runs in a separate tmux command; a dialog appearing between commands is not caught.
    // #1172 tracks composing the check and input into the same command.
    func requireClearDialog(_ session: Session) async throws {
        switch await inspectDialog(session) {
        case .clear: return
        case .dialog(let kind, _): throw TmuxDialogVeto(cause: .known(title: kind.title))
        case .unknown: throw TmuxDialogVeto(cause: .uninspectable)
        }
    }
}
