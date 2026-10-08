import Foundation
import Testing
@testable import HailDaemonKit

/// #306 review: a real shell whose prompt carries a glyph outside the known-width table. The suite name matches
/// `TmuxDeliveryCommit`, so it runs in the serial timing lane (a real subprocess, #208).
@Suite(.enabled(if: TmuxProbe.available), .serialized, .timeLimit(.minutes(1)))
struct TmuxDeliveryCommitShellPromptTests {
    private static let timing = TmuxSubmitTiming(
        settleFloor: .milliseconds(20), pollInterval: .milliseconds(20), quiet: .milliseconds(150),
        settleLimit: .seconds(5), confirmLimit: .seconds(2)
    )

    @Test func aShellWhosePromptHasAGlyphOfUnknownWidthTakesEachDeliveryAndConfirms() async throws {
        // #306 review: bash with oh-my-zsh's default `➜ ~ ` prompt; U+279C is outside the known-width table.
        let socket = "hail-sh-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let runner = ProcessCommandRunner()
        let shell = "env LANG=en_US.UTF-8 PS1='\u{279C} ~ ' /bin/bash --norc --noprofile"
        _ = try await runner.run("tmux", ["-L", socket, "-f", "/dev/null", "new-session", "-d", "-s", "sh",
                                          "-x", "80", "-y", "23", shell])
        var failure: (any Error)?
        do {
            let outcomes = OutcomeLog()
            let adapter = TmuxAdapter(runner: runner, tmux: "tmux", socket: socket, pollInterval: nil,
                                      submitTiming: Self.timing, submitObserver: { outcomes.append($0) })
            try await waitFor { (try? self.capture(socket, runner))?.contains("\u{279C} ~") == true }
            try await adapter.deliver("echo one", to: "sh", binding: nil)
            try await adapter.deliver("echo two", to: "sh", binding: nil)
            try await waitFor { (try? self.capture(socket, runner))?.contains("\ntwo\n") == true }
            #expect(outcomes.all == [.confirmed, .confirmed])
            let screen = try capture(socket, runner)
            #expect(screen.contains("\none\n") && screen.contains("\ntwo\n"))
            // A pending line that exactly fills the 80 columns after the 4-column prompt: readline leaves the cursor
            // in column 0 of the next row. The same text is not appended to it (#306 review, Codex P2).
            let filling = "echo " + String(repeating: "x", count: 71)
            _ = try await runner.run("tmux", ["-L", socket, "send-keys", "-t", "sh", "-l", "--", filling])
            try await waitFor { (try? self.capture(socket, runner))?.contains(filling) == true }
            await #expect(throws: AdapterError.self) { try await adapter.deliver(filling, to: "sh", binding: nil) }
            #expect(try capture(socket, runner).filter { $0 == "x" }.count == 71, "one copy, unsubmitted")
        } catch {
            failure = error
        }
        _ = try? await runner.run("tmux", ["-L", socket, "kill-server"])
        let base = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"
        try? FileManager.default.removeItem(atPath: "\(base)/tmux-\(getuid())/\(socket)")
        if let failure { throw failure }
    }

    private func capture(_ socket: String, _ runner: ProcessCommandRunner) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-L", socket, "capture-pane", "-p", "-t", "sh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
