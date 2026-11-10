import Testing
@testable import HailDaemonKit

@Suite struct TmuxDialogDetectionTests {
    @Test func kindNamesAreBoundedAndPinned() {
        for kind in DialogKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.spokenName.isEmpty)
        }
        #expect(DialogKind.allCases.map(\.title) == [
            "Computer Use needs macOS permissions", "Computer Use wants to control these apps",
            "a tool permission dialog", "a dialog"
        ])
        #expect(DialogKind.allCases.map(\.spokenName) == [
            "Computer Use permissions dialog", "Computer Use app approval dialog",
            "tool permission dialog", "dialog"
        ])
    }

    @Test(arguments: [
        ("Computer Use needs macOS permissions", DialogKind.computerUsePermissions),
        ("Computer Use wants to control these apps", DialogKind.computerUseAppApproval)
    ])
    func knownTitles(_ title: String, _ kind: DialogKind) {
        #expect(TmuxAdapter.classifyDialog(visibleScreen: title) == .dialog(kind: kind, title: title))
    }

    @Test(arguments: [
        "Enter to confirm · Esc to cancel", "Return to select · Esc to cancel",
        "Enter to submit · Esc to cancel", "Press Esc to cancel",
        "Edit and press Enter to retry, or Esc to cancel", "ESC TO CANCEL"
    ])
    func modalFooters(_ footer: String) {
        #expect(TmuxAdapter.classifyDialog(visibleScreen: footer) == .dialog(kind: .modalFooter, title: "a dialog"))
    }

    @Test(arguments: [
        "Do you want to proceed?", "Do you want to make this edit to synthetic.swift?",
        "Do you want to create synthetic.swift?"
    ])
    func toolQuestions(_ question: String) {
        let screen = "\(question)\n❯ 1. Yes\n2. No"
        let expected = TmuxDialogState.dialog(kind: .toolPermission, title: "a tool permission dialog")
        #expect(TmuxAdapter.classifyDialog(visibleScreen: screen) == expected)
    }

    @Test func bordersAndWrapping() {
        let screen = """
        ╭────────────────────╮
        │ Computer Use wants to control these  │
        │ apps                                │
        ╰────────────────────╯
        """
        let expected = TmuxDialogState.dialog(
            kind: .computerUseAppApproval, title: "Computer Use wants to control these apps"
        )
        #expect(TmuxAdapter.classifyDialog(visibleScreen: screen) == expected)
        let footer = "│ Enter to confirm ·\n│ Esc to cancel │"
        #expect(TmuxAdapter.classifyDialog(visibleScreen: footer) == .dialog(kind: .modalFooter, title: "a dialog"))
    }

    @Test(arguments: [
        "█ ⚠ Computer Use needs macOS permissions: ▌",
        "⏺ Computer Use needs macOS permissions",
        "⚠ Computer Use needs macOS\n│ permissions: █"
    ])
    func decoratedTitles(_ screen: String) {
        let expected = TmuxDialogState.dialog(
            kind: .computerUsePermissions, title: "Computer Use needs macOS permissions"
        )
        #expect(TmuxAdapter.classifyDialog(visibleScreen: screen) == expected)
    }

    @Test func bottomRegionUsesTwelveNonblankLines() {
        let transcript = "Do you want to proceed?\n1. Yes\nEnter to confirm · Esc to cancel\n"
        let later = (1...12).map { "ordinary visible row \($0)\n\n" }.joined()
        #expect(TmuxAdapter.classifyDialog(visibleScreen: transcript + later) == .clear)
        let boundary = "Do you want to proceed?\n1. Yes\n" + (1...10).map { "row \($0)" }.joined(separator: "\n")
        let expected = TmuxDialogState.dialog(kind: .toolPermission, title: "a tool permission dialog")
        #expect(TmuxAdapter.classifyDialog(visibleScreen: boundary) == expected)
        let title = "Computer Use needs macOS permissions\n" + later
        let known = TmuxDialogState.dialog(
            kind: .computerUsePermissions, title: "Computer Use needs macOS permissions"
        )
        #expect(TmuxAdapter.classifyDialog(visibleScreen: title) == known)
    }

    @Test(arguments: [
        "esc to interrupt", "Do you want to proceed?", "1. Yes", "Esc to cancel while editing",
        "A discussion of Computer Use needs macOS permissions in prose",
        "quoted Do you want to proceed?\n1. Yes"
    ])
    func normalScreens(_ screen: String) {
        #expect(TmuxAdapter.classifyDialog(visibleScreen: screen) == .clear)
    }

    @Test func caseInsensitiveUnfocusedToolOption() {
        let screen = "do YOU want TO proceed?\n1. YES"
        let expected = TmuxDialogState.dialog(kind: .toolPermission, title: "a tool permission dialog")
        #expect(TmuxAdapter.classifyDialog(visibleScreen: screen) == expected)
    }

    @Test(arguments: [DialogCaptureRunner.Failure.thrown, .nonzero, .empty])
    func inspectionFailuresAreUnknown(_ failure: DialogCaptureRunner.Failure) async {
        let runner = DialogCaptureRunner(failure: failure)
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let session = TmuxAdapter.Session(id: "$1", created: "1", paneID: "%1", panePID: "1", name: "synthetic")
        #expect(await adapter.inspectDialog(session) == .unknown)
        #expect(await runner.calls == [["tmux", "capture-pane", "-p", "-t", "%1"]])
    }
}

actor DialogCaptureRunner: CommandRunner {
    enum Failure: Sendable { case thrown, nonzero, empty }
    struct CaptureError: Error {}
    let failure: Failure
    private(set) var calls: [[String]] = []

    init(failure: Failure) { self.failure = failure }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        calls.append([executable] + arguments)
        switch failure {
        case .thrown: throw CaptureError()
        case .nonzero: return CommandResult(exitCode: 1, stdout: "ordinary prompt")
        case .empty: return CommandResult(exitCode: 0, stdout: "")
        }
    }
}
