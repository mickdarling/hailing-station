import Foundation

/// Pastes only to agent panes (#608).
extension TmuxAdapter {
    /// The paste itself, bracketed when the target asked for it, and `-d` deletes the buffer. A framed paste (#608)
    /// goes only to an agent: the tmux server checks the pane's foreground command and pastes in the same command, so
    /// no check-then-paste gap is left on this side. `pasting` runs once text may have reached the pane.
    func pasteBuffer(_ buffer: String, holding text: String, into pane: String, pasting: () -> Void) async throws {
        if text.hasPrefix(PastedContent.begin + " ") {
            try await pasteToAgent(buffer: buffer, pane: pane, pasting: pasting)
            return
        }
        pasting()
        try await tmux(["paste-buffer", "-p", "-d", "-b", buffer, "-t", pane], failure: AdapterError.deliveryFailed)
    }

    /// Foreground commands of a pane that runs an agent session (#608): Claude Code (`claude`, or `claude.exe` for the
    /// native build, as tmux 3.5 reports it) and Codex. Anything else, a shell or `node` included, is refused.
    static let agentCommands = ["claude", "claude.exe", "codex"]

    /// `if-shell -F` evaluates `#{pane_current_command}` for the pane inside the tmux server and runs the paste only
    /// when it is an agent; otherwise the else branch prints a marker and nothing reaches the pane. The buffer and pane
    /// names are generated (`hail-<uuid>`, `%<n>`), so the command strings hold no tmux syntax of their own.
    func pasteToAgent(buffer: String, pane: String, pasting: () -> Void) async throws {
        guard buffer.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              pane.hasPrefix("%"), pane.dropFirst().allSatisfy(\.isNumber) else {
            throw AdapterError.deliveryFailed("unexpected tmux buffer or pane name")
        }
        let refused = "hail-paste-not-agent"
        let result: CommandResult
        do {
            result = try await tmux([
                "if-shell", "-F", "-t", pane, Self.isAgentFormat,
                "paste-buffer -p -d -b \(buffer) -t \(pane)", "display-message -p \(refused)"
            ], failure: AdapterError.deliveryFailed)
        } catch {
            pasting() // Unknown whether it pasted: treated as typed, so the pane is not reused blindly.
            throw error
        }
        // A refusal pasted nothing, so the pane stays clean; the caller deletes the buffer.
        if result.stdout.contains(refused) { throw AdapterError.deliveryFailed(PastedContent.agentOnlyRefusal) }
        pasting()
    }

    /// `1` when the pane's foreground command is one of `agentCommands`: nested `#{||:a,b}` over `#{==:...}` tests.
    static var isAgentFormat: String {
        let tests = agentCommands.map { "#{==:#{pane_current_command},\($0)}" }
        return tests.dropFirst().reduce(tests[0]) { "#{||:\($0),\($1)}" }
    }
}
