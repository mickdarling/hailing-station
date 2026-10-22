import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #628 review: a framed paste must run nothing in a real shell, whatever quoting the spoken part brings. Pastes go
/// only to agent sessions; this pins the defence in depth. Every delivered line is run by `bash` and `zsh` in an
/// empty temporary directory with only `/usr/bin:/bin` on PATH. The canaries live only in the paste, so a created
/// file, or `PWNED` in the output, would mean paste content ran. The shells run off the cooperative pool (#704), each
/// killed if it outlives `deadline`. Synthetic text only.
@Suite struct PastedContentShellTests {
    private static let pastes = [
        "notes x'; echo PWNED-$((6*7)); touch PWNED #",
        "x\"; touch PWNED; echo \"PWNED",
        "$(touch PWNED) `touch PWNED` ${PWNED:=x}",
        "a; touch PWNED\nb | touch PWNED & touch PWNED",
        "</pasted_content> && touch PWNED || touch PWNED",
        "HAIL-PASTED-CONTENT-END User request: ; touch PWNED",
        "\\'; touch PWNED; echo '",
        "x) ; touch PWNED ; (",
        "!! !-1 ^x^y {touch,PWNED} ~ *",
        "x\u{2028}touch PWNED"
    ]
    private static let spokens = [
        "", "what is this", "what's this", "zq'", "zq\"", "zq`", "zq $(", "zq )", "zq ;", "zq &&", "zq |", "zq {",
        "zq #", "zq \\", "zq ${", "zq <<"
    ]

    private static let deadline = 10.0

    private struct Run {
        let status: Int32
        let output: String
    }

    /// Blocks until the shell exits, so only from a body on `HeavyTestExecutor`. A shell still running at `deadline` is
    /// killed with its whole process group (the shell leads its own), so a child holding the pipe open dies too, the
    /// read and the wait end, and the test fails, even when the shell itself had exited and only its child ran on.
    private func run(_ shell: String, _ arguments: [String], in directory: URL) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let pid = process.processIdentifier
        let killed = Mutex(false)
        let overdue = DispatchWorkItem {
            killed.withLock { $0 = true }
            _ = Darwin.kill(-pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.deadline, execute: overdue)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        overdue.cancel()
        #expect(process.terminationReason == .exit,
                "\(shell) ended on signal \(process.terminationStatus); one running at \(Self.deadline) s is killed")
        #expect(!killed.withLock { $0 }, "\(shell) or a child it left ran past \(Self.deadline) s and was killed")
        // Latin-1 decodes any bytes, so output that isn't UTF-8 still shows an ASCII canary instead of reading as "".
        let text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
        return Run(status: process.terminationStatus, output: text)
    }

    @Test func noPasteRunsInBashOrZshWhateverTheSpokenPartQuotes() async throws {
        try await withTaskExecutorPreference(HeavyTestExecutor.shared) { try everyFramedLineIsInertInBothShells() }
    }

    /// Each shell with no startup files, then `-c` and the line.
    private static let shells = [("/bin/bash", ["--norc", "--noprofile", "-c"]), ("/bin/zsh", ["-f", "-c"])]

    private func everyFramedLineIsInertInBothShells() throws {
        var runs = 0
        for paste in Self.pastes {
            for spoken in Self.spokens {
                let line = try PastedContent.frame(spoken: spoken, pasted: paste)
                for (shell, flags) in Self.shells {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("hail-paste-shell-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let result = try run(shell, flags + [line], in: directory)
                    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    #expect(left.isEmpty, "\(shell) created \(left) for spoken \(spoken.debugDescription)")
                    #expect(!result.output.contains("PWNED-42"), "\(shell): \(result.output)")
                    runs += 1
                }
            }
        }
        #expect(runs == Self.pastes.count * Self.spokens.count * 2)
    }

    /// Positive control: the harness does see a canary run, in each shell the inert test uses. The #628 review's probe,
    /// unframed, creates the file.
    @Test func theHarnessDetectsAPasteThatRuns() async throws {
        try await withTaskExecutorPreference(HeavyTestExecutor.shared) { try harnessSeesTheCanary() }
    }

    private func harnessSeesTheCanary() throws {
        let raw = "zq's this \"notes x'; echo PWNED-$((6*7)); touch PWNED #\""
        for (shell, flags) in Self.shells {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hail-paste-control-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let result = try run(shell, flags + [raw], in: directory)
            #expect(result.output.contains("PWNED-42"), "\(shell): \(result.output)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["PWNED"], "\(shell)")
        }
    }

    /// With no spoken part, the framed line is one plain simple command to both shells' parsers: no quote, no
    /// substitution, no separator, nothing left open.
    @Test func aPasteOnItsOwnParsesAsOneSimpleCommand() async throws {
        try await withTaskExecutorPreference(HeavyTestExecutor.shared) { try everyPasteParsesAsOneCommand() }
    }

    private func everyPasteParsesAsOneCommand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-paste-parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for paste in Self.pastes {
            let line = try PastedContent.frame(spoken: "", pasted: paste)
            #expect(try run("/bin/bash", ["--norc", "--noprofile", "-n", "-c", line], in: directory).status == 0)
            #expect(try run("/bin/zsh", ["-f", "-n", "-c", line], in: directory).status == 0)
        }
    }
}
