import Foundation
import Testing
@testable import HailDaemonKit

/// True when both tmux and python3 run here; the fake-TUI suite is skipped otherwise.
enum FakeTUIProbe {
    static let available: Bool = TmuxProbe.available && {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import termios, tty"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()
}

/// #304 against a real scratch tmux server and a fake TUI that follows Claude Code's observed input rules, with its
/// event loop frozen (SIGSTOP) around the paste and the Enter. The suite name matches `TmuxDeliveryCommit`, so it
/// runs in the serial timing lane of `scripts/verify.sh` (real subprocesses and wall-clock stalls, #208).
@Suite(.enabled(if: FakeTUIProbe.available), .serialized, .timeLimit(.minutes(1)))
struct TmuxDeliveryCommitFakeTUITests {
    private static let timing = TmuxSubmitTiming(
        settleFloor: .milliseconds(20), pollInterval: .milliseconds(20), quiet: .milliseconds(150),
        settleLimit: .seconds(5), confirmLimit: .seconds(2)
    )

    private struct Step {
        let text: String
        let stall: StallPoint?
        let duration: Duration
        init(_ text: String, _ stall: StallPoint?, _ duration: Duration) {
            self.text = text
            self.stall = stall
            self.duration = duration
        }
    }

    /// An ambient-shaped prompt: JSON context, then the reply instruction, `size` characters long.
    private static func payload(_ tag: String, size: Int) -> String {
        let head = "Instruction \(tag): reply with one word. Raw turns (JSON, admitted record): {\"turns\":["
        let tail = "]} Reply: answer briefly; it is spoken aloud. Code word \(tag) end."
        var turns: [String] = []
        while head.count + tail.count + turns.joined(separator: ",").count < size {
            turns.append("{\"speaker\":\"S\(turns.count % 2)\",\"text\":\"filler \(turns.count) about nothing\"}")
        }
        return String((head + turns.joined(separator: ",") + tail).suffix(size))
    }

    private func withPane(_ body: (FakeTUIPane) async throws -> Void) async throws {
        let pane = try FakeTUIPane()
        var failure: (any Error)?
        do {
            try await pane.start()
            try await body(pane)
        } catch {
            failure = error
        }
        await pane.stop()
        if let failure { throw failure }
    }

    @Test func everyDeliverySubmitsExactlyOnceWholeAndInOrderThroughStalls() async throws {
        try await withPane { pane in
            let runner = StallingRunner()
            let outcomes = OutcomeLog()
            let adapter = TmuxAdapter(runner: runner, tmux: "tmux", socket: pane.socket, pollInterval: nil,
                                      submitTiming: Self.timing, submitObserver: { outcomes.append($0) })
            let plan: [Step] = [
                Step(Self.payload("A", size: 120), nil, .zero),
                Step(Self.payload("B", size: 1_839), .beforePaste, .milliseconds(600)),
                Step(Self.payload("C", size: 5_000), .afterPaste, .milliseconds(600)),
                Step(Self.payload("D", size: 618), .afterPaste, .milliseconds(1_200)),
                Step(Self.payload("E", size: 2_455), .afterEnter, .milliseconds(800)),
                Step(Self.payload("F", size: 1_000), .beforePaste, .milliseconds(300))
            ]
            for step in plan {
                if let point = step.stall { runner.arm(point, for: step.duration, pid: try pane.pid) }
                try await adapter.deliver(step.text, to: "tui", binding: nil)
            }
            try await waitFor { try pane.submits().count >= plan.count }
            #expect(try pane.submits() == plan.map(\.text), "each text whole, once, in order: no merge and no loss")
            #expect(outcomes.all.allSatisfy { $0 == .confirmed }, "outcomes: \(outcomes.all)")
        }
    }

    /// The fake reproduces both #304 failures under the old per-chunk typing, so the suite above is a real test.
    @Test func chunkedTypingThroughAStallLosesTheEnterAndAShortReadAfterALongOneLosesText() async throws {
        try await withPane { pane in
            let text = Self.payload("G", size: 1_839)
            let pid = try pane.pid
            // Old delivery: 400-character literal sends; the loop freezes after the first, the Enter queues behind
            // the rest and arrives in the same read, so it becomes a newline.
            try await pane.tmux(["send-keys", "-t", "tui", "-l", "--", String(text.prefix(400))])
            try await Task.sleep(for: .milliseconds(100))
            kill(pid, SIGSTOP)
            for chunk in TmuxAdapter.chunks(String(text.dropFirst(400)), size: 400) {
                try await pane.tmux(["send-keys", "-t", "tui", "-l", "--", chunk])
            }
            try await pane.tmux(["send-keys", "-t", "tui", "Enter"])
            kill(pid, SIGCONT)
            try await Task.sleep(for: .milliseconds(500))
            #expect(try pane.submits().isEmpty, "the Enter was taken as a newline")
            try await pane.tmux(["send-keys", "-t", "tui", "Enter"])
            try await waitFor { try pane.submits().count == 1 }
            // A later Enter submits what the input kept: a stray newline at least, and on macOS (reads of at most
            // about 1 KB) usually a lost middle as well.
            let kept = try #require(try pane.submits().first)
            #expect(kept != text && kept.hasPrefix(String(text.prefix(400))) && kept.hasSuffix("end.\n"))

            // A read over 800 characters, then a shorter one inside the 100 ms paste window: the paste is lost.
            let long = Self.payload("H", size: 1_000), short = " and a short tail"
            kill(pid, SIGSTOP)
            try await pane.tmux(["send-keys", "-t", "tui", "-l", "--", long])
            kill(pid, SIGCONT)
            try await Task.sleep(for: .milliseconds(30))
            try await pane.tmux(["send-keys", "-t", "tui", "-l", "--", short])
            try await Task.sleep(for: .milliseconds(300))
            try await pane.tmux(["send-keys", "-t", "tui", "Enter"])
            try await waitFor { try pane.submits().count == 2 }
            #expect(try pane.submits().last == short, "the long read was lost")
        }
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
