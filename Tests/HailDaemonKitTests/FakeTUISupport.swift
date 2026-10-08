import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// A raw-mode stand-in for a full-screen agent TUI (#304), written to a scratch file and run in a scratch tmux pane.
/// Its input rules are the ones observed in Claude Code 2.1.x:
/// - one read holding printable text and a CR takes the CR as a newline in the input, not a submit;
/// - a CR is a submit when it is a read on its own, or follows a bracketed-paste end marker;
/// - a bracketed paste is taken whole; one longer than 800 characters is shown as `[Pasted text #N]`;
/// - an unbracketed read longer than 800 characters is held 100 ms as a paste, and a shorter read in that window
///   is applied to the input as it was before the paste, which loses the paste (the race behind lost chunks).
/// Each submit is appended to the log as one JSON line. The script writes its pid so a test can SIGSTOP it; it runs
/// under a wrapper shell, because tmux resumes a stopped pane process at once when it is the pane's own pid.
enum FakeTUI {
    static let script = #"""
import json, os, select, sys, termios, time, tty
log, pidfile = sys.argv[1], sys.argv[2]
tty.setraw(0)
os.write(1, b"\x1b[?2004h")
segments, history, pending, count = [], [], None, [0]
START, END = "\x1b[200~", "\x1b[201~"
def text(segs): return "".join(s[0] for s in segs)
def render():
    shown = "".join(s[1] if s[1] else s[0] for s in segments).replace("\n", "\r\n  ")
    echo = "".join("> " + h[-60:] + "\r\n" for h in history[-3:])
    os.write(1, ("\x1b[2J\x1b[H" + echo + "\r\n❯ " + shown).encode())
def placeholder(t):
    if len(t) <= 800: return None
    count[0] += 1
    return "[Pasted text #%d]" % count[0]
def submit():
    global segments
    with open(log, "a") as f: f.write(json.dumps({"text": text(segments)}) + "\n")
    history.append(text(segments).replace("\n", " ")); segments = []
def plain(chunk, after_paste):
    global pending, segments
    if chunk == "\r" or (after_paste and chunk.startswith("\r")):
        submit(); chunk = chunk[1:]
        if not chunk: return
    chunk = chunk.replace("\r", "\n")
    if len(chunk) > 800:
        pending = (list(segments), chunk, time.time() + 0.1); return
    if pending:
        segments, pending = pending[0] + [(chunk, None)], None
    else:
        segments.append((chunk, None))
open(pidfile, "w").write(str(os.getpid()))
render()
buf = ""
while True:
    wait = max(0, pending[2] - time.time()) if pending else None
    ready, _, _ = select.select([0], [], [], wait)
    if not ready:
        segments.append((pending[1], placeholder(pending[1]))); pending = None; render(); continue
    data = os.read(0, 65536).decode("utf-8", "replace")
    buf += data
    after_paste = False
    while buf:
        if buf.startswith(START):
            end = buf.find(END)
            if end < 0: break
            body = buf[len(START):end].replace("\r", "\n")
            segments.append((body, placeholder(body))); buf = buf[end + len(END):]; after_paste = True
            continue
        cut = buf.find(START)
        chunk, buf = (buf, "") if cut < 0 else (buf[:cut], buf[cut:])
        plain(chunk, after_paste); after_paste = False
    render()
"""#
}

/// A scratch tmux server on its own socket with one 80x23 pane running the fake TUI under a wrapper shell.
final class FakeTUIPane: Sendable {
    let socket = "hail-tui-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    let directory: URL
    var log: URL { directory.appendingPathComponent("submits.jsonl") }
    private var pidFile: URL { directory.appendingPathComponent("pid") }

    init() throws {
        directory = URL(fileURLWithPath: "/tmp/hail-tui-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FakeTUI.script.write(to: directory.appendingPathComponent("tui.py"), atomically: true, encoding: .utf8)
    }

    func start() async throws {
        let command = "/usr/bin/env python3 '\(directory.path)/tui.py' '\(log.path)' '\(pidFile.path)'; sleep 600"
        let result = try await tmux(["-f", "/dev/null", "new-session", "-d", "-s", "tui", "-x", "80", "-y", "23",
                                     "/bin/sh -c \"\(command)\""])
        try #require(result.exitCode == 0, "tmux new-session: \(result.errorText)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (try? await tmux(["capture-pane", "-p", "-t", "tui"]).stdout.contains("\u{276F}")) != true {
            try #require(ContinuousClock.now < deadline, "the fake TUI never drew its prompt")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func stop() async {
        _ = try? await tmux(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
        let base = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"
        try? FileManager.default.removeItem(atPath: "\(base)/tmux-\(getuid())/\(socket)")
    }

    var pid: pid_t {
        get throws { try #require(pid_t((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "")) }
    }

    /// Every submit the fake recorded, in order.
    func submits() throws -> [String] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return try (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n").map {
            try JSONDecoder().decode([String: String].self, from: Data($0.utf8))["text"] ?? ""
        }
    }

    @discardableResult
    func tmux(_ arguments: [String]) async throws -> CommandResult {
        try await ProcessCommandRunner().run("tmux", ["-L", socket] + arguments)
    }
}

/// Where a stall of the fake TUI's event loop starts, relative to the adapter's commands.
enum StallPoint: Sendable { case beforePaste, afterPaste, beforeEnter, afterEnter }

/// Runs tmux for real and freezes the fake TUI (SIGSTOP, then SIGCONT after `duration`) at the armed point once.
final class StallingRunner: CommandRunner {
    private struct Stall {
        let point: StallPoint
        let duration: Duration
        let pid: pid_t
    }
    private let base = ProcessCommandRunner()
    private let armed = Mutex<Stall?>(nil)

    func arm(_ point: StallPoint, for duration: Duration, pid: pid_t) {
        armed.withLock { $0 = Stall(point: point, duration: duration, pid: pid) }
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        let point: StallPoint? = arguments.contains("paste-buffer") ? .beforePaste
            : (arguments.last == "Enter" ? .afterEnter : nil)
        if point == .beforePaste { freeze(at: .beforePaste) }
        if point == .afterEnter { freeze(at: .beforeEnter) }
        let result = try await base.run(executable, arguments)
        if point == .beforePaste { freeze(at: .afterPaste) }
        if point == .afterEnter { freeze(at: .afterEnter) }
        return result
    }

    private func freeze(at point: StallPoint) {
        let due = armed.withLock { armed -> Stall? in
            guard let stall = armed, stall.point == point else { return nil }
            armed = nil
            return stall
        }
        guard let due else { return }
        kill(due.pid, SIGSTOP)
        Task.detached {
            try? await Task.sleep(for: due.duration)
            kill(due.pid, SIGCONT)
        }
    }
}
