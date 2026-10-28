#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// The version probe and launch-time identity, over actual pipes with invented children.
extension CodexLauncherTests {
    @Test func theProbePassesOnlyVersionArgumentAndAnEmptyEnvironment() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = try Self.script(#"""
            #!/usr/bin/perl
            print "codex-cli " . scalar(keys %ENV) . "." . scalar(@ARGV) . ".$ARGV[0]\n";
            """#, in: folder)
        let output = try await CodexLauncher.readVersion(child)
        #expect(String(data: output, encoding: .utf8) == "codex-cli 0.1.--version\n")
    }

    @Test func oversizedProbeOutputIsRefused() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backstop = try ProbeChildBackstop(in: folder, after: TestTiming.bound(20))
        defer { backstop.stop() }
        let child = try Self.script("#!/usr/bin/perl\n$|=1; print 'x' x 4096; \(backstop.wait)\n", in: folder)
        let started = ContinuousClock.now
        await #expect(throws: CodexLaunchError.versionUnavailable) {
            _ = try await CodexLauncher.readVersion(child, deadline: .seconds(60))
        }
        // With a 60 s deadline and a child that runs up to 300 s, finishing early proves the byte cap refused it,
        // even on loaded CI.
        #expect(ContinuousClock.now - started < .seconds(TestTiming.bound(20)))
    }

    @Test func aSilentProbePastItsDeadlineIsRefusedAndReaped() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("pid").path
        let backstop = try ProbeChildBackstop(in: folder, after: TestTiming.bound(20))
        defer { backstop.stop() }
        let child = try Self.script(
            "#!/usr/bin/perl\n$SIG{TERM}='IGNORE'; open(F,'>','\(pidFile)'); print F $$; close F; \(backstop.wait)\n",
            in: folder)
        let started = ContinuousClock.now
        await #expect(throws: CodexLaunchError.versionUnavailable) {
            _ = try await CodexLauncher.readVersion(child, deadline: .seconds(2))
        }
        // The child ignores TERM and runs up to 300 s.
        #expect(ContinuousClock.now - started < .seconds(TestTiming.bound(20)))
        let pid = try #require(pid_t(String(contentsOfFile: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func aBinarySwappedAfterVerificationIsRefusedAtLaunch() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("codex").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        #expect(chmod(copy, 0o700) == 0)
        let evidence = try await CodexLauncher.verify(path: copy, requirement: Self.apple,
                                                      probe: Self.fixed("codex-cli 0.159.0\n"))
        try FileManager.default.removeItem(atPath: copy)
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: copy)
        #expect(chmod(copy, 0o700) == 0)
        #expect(throws: CodexLaunchError.binaryChanged) { _ = try evidence.appServerCommand(environment: []) }
        await #expect(throws: CodexLaunchError.binaryChanged) {
            let setup = try CodexLaunchSetup.prepare(root: folder.path, host: [:])
            _ = try await CodexAppServerAdapter.withOwnedAdapter(launch: evidence, setup: setup) { _ in
                Issue.record("operation entered for a swapped binary")
            }
        }
    }
}

/// #1012: a probe child runs only while its marker file exists, and for at most 300 s, so the bounds can scale on CI
/// and still prove the launcher killed it. Removing the scratch folder at teardown ends a child the launcher left
/// alive, and the backstop removes the marker after the scaled bound plus 5 s, so a launcher regression can neither
/// hold CI nor leak the child. It sends no signal, so a reused PID is never at risk.
private struct ProbeChildBackstop {
    let wait: String
    private let task: Task<Void, Never>
    init(in folder: URL, after seconds: Double) throws {
        let marker = folder.appendingPathComponent("run").path
        guard FileManager.default.createFile(atPath: marker, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        wait = "for (1..3000) { last unless -e '\(marker)'; select(undef, undef, undef, 0.1); }"
        task = Task {
            guard (try? await Task.sleep(for: .seconds(seconds + 5))) != nil else { return }
            try? FileManager.default.removeItem(atPath: marker)
        }
    }
    func stop() { task.cancel() }
}
#endif
