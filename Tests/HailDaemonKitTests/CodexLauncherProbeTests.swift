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
        let child = try Self.script("#!/usr/bin/perl\n$|=1; print 'x' x 4096; sleep 30;\n", in: folder)
        let started = ContinuousClock.now
        await #expect(throws: CodexLaunchError.versionUnavailable) { _ = try await CodexLauncher.readVersion(child) }
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test func aSilentProbePastItsDeadlineIsRefusedAndReaped() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("pid").path
        let child = try Self.script(
            "#!/usr/bin/perl\n$SIG{TERM}='IGNORE'; open(F,'>','\(pidFile)'); print F $$; close F; sleep 30;\n",
            in: folder)
        let started = ContinuousClock.now
        await #expect(throws: CodexLaunchError.versionUnavailable) {
            _ = try await CodexLauncher.readVersion(child, deadline: .seconds(2))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
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
            _ = try await CodexAppServerAdapter.withOwnedAdapter(launch: evidence, environment: []) { _ in
                Issue.record("operation entered for a swapped binary")
            }
        }
    }
}
#endif
