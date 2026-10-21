import Foundation
import Testing
@testable import HailDaemonKit

/// #675 review: the Enter after a framed paste is checked like the paste. Here the "agent" takes the first bytes of
/// the paste and then turns into a shell, as if the agent exited between the paste and the Enter. The delivery must
/// fail with the agent-only reason and the shell must never receive an Enter. Against a real scratch tmux server.
@Suite(.enabled(if: TmuxProbe.available), .serialized, .timeLimit(.minutes(1)))
struct TmuxPasteEnterTests {
    /// Reads one chunk without waiting for a line, then becomes /bin/sh, which keeps the rest of the line unsubmitted.
    private static let source = """
        #include <termios.h>
        #include <unistd.h>
        int main(void) {
            struct termios t; tcgetattr(0, &t); struct termios raw = t; raw.c_lflag &= ~(ICANON | ECHO);
            tcsetattr(0, TCSANOW, &raw); char b[16]; read(0, b, sizeof b); tcsetattr(0, TCSANOW, &t);
            execl("/bin/sh", "sh", (char *)0); return 1;
        }
        """

    private func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    @Test func noEnterReachesAPaneWhoseAgentLeftAfterThePaste() async throws {
        let socket = "hail-enter-\(getpid())"
        let runner = ProcessCommandRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-enter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = directory.appendingPathComponent("claude").path
        let file = directory.appendingPathComponent("leaves.c")
        try Self.source.write(to: file, atomically: true, encoding: .utf8)
        let built = try await runner.run("/usr/bin/cc", ["-o", agent, file.path])
        try #require(built.exitCode == 0, "\(built.errorText)")
        _ = try await runner.run("tmux", ["-L", socket, "new-session", "-d", "-s", "leaves", "-x", "200", "-y", "50",
                                          agent])
        var failure: (any Error)?
        do {
            let adapter = TmuxAdapter(runner: runner, socket: socket, pollInterval: nil)
            let look = ["-L", socket, "display-message", "-p", "-t", "leaves", "#{pane_current_command}"]
            let ready = try await eventually { try await runner.run("tmux", look).stdout.hasPrefix("claude") }
            try #require(ready, "the pane never ran claude")
            let framed = try PastedContent.frame(spoken: "summarise this", pasted: "synthetic notes")
            await #expect(throws: AdapterError.deliveryFailed(PastedContent.agentOnlyRefusal)) {
                try await adapter.deliver(framed, to: "leaves", binding: nil)
            }
            // The paste went to the agent before it left, and the shell never got an Enter to run anything.
            try await Task.sleep(for: .milliseconds(500))
            let screen = try await adapter.capture("leaves")
            // With an Enter the shell would run the rest of the line and say "not found" (checked by removing the
            // gate: this assertion and the refusal above both fail).
            #expect(!screen.contains("not found"))
        } catch {
            failure = error
        }
        _ = try await runner.run("tmux", ["-L", socket, "kill-server"])
        try? FileManager.default.removeItem(atPath: "/tmp/tmux-\(getuid())/\(socket)")
        if let failure { throw failure }
    }
}
