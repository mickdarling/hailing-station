#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Synthetic only: system binaries for signature checks, invented scripts for the version probe.
/// No real Codex binary, account, thread or inference is used.
@Suite struct CodexLauncherTests {
    private static let apple = "anchor apple"
    private static func fixed(_ text: String) -> @Sendable (String) async throws -> Data {
        { _ in Data(text.utf8) }
    }
    private static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-launcher-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }
    private static func script(_ body: String, in folder: URL) throws -> String {
        let path = folder.appendingPathComponent("synthetic-\(UUID())").path
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        guard chmod(path, 0o700) == 0 else { throw CodexLaunchError.invalidPath }
        return path
    }

    @Test func aSignedSystemBinaryWithAnAllowedVersionYieldsExactEvidence() async throws {
        let evidence = try await CodexLauncher.verify(path: "/bin/ls", requirement: Self.apple,
                                                      probe: Self.fixed("codex-cli 0.162.0-alpha.17.2\n"))
        #expect(evidence.executable == "/bin/ls")
        #expect(evidence.version == "0.162.0-alpha.17.2")
        let command = try evidence.appServerCommand(environment: ["HOME=/synthetic"])
        #expect(command.executable == "/bin/ls")
        #expect(command.arguments == ["app-server", "--listen", "stdio://"])
        #expect(command.environment == ["HOME=/synthetic"])
    }

    @Test func symlinksResolveToTheRealBinaryBeforeAnyCheck() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("codex").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/bin/ls")
        let evidence = try await CodexLauncher.verify(path: link, requirement: Self.apple,
                                                      probe: Self.fixed("codex-cli 0.159.0\n"))
        #expect(evidence.executable == "/bin/ls")
    }

    @Test(arguments: ["bin/ls", "", "/nonexistent-synthetic/codex", "/bin"])
    func relativeMissingOrNonFilePathsAreRefused(path: String) async {
        await #expect(throws: (any Error).self) {
            _ = try await CodexLauncher.verify(path: path, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test func aShellWrapperIsRefusedBeforeSignatureOrProbe() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrapper = try Self.script("#!/bin/sh\nexec /bin/ls \"$@\"\n", in: folder)
        await #expect(throws: CodexLaunchError.notExecutable) {
            _ = try await CodexLauncher.verify(path: wrapper, requirement: Self.apple) { _ in
                Issue.record("probe ran for a wrapper"); return Data()
            }
        }
    }

    @Test func aGroupWritableCopyIsRefusedAsUnsafe() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("codex").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        #expect(chmod(copy, 0o770) == 0)
        await #expect(throws: CodexLaunchError.unsafeOwnership) {
            _ = try await CodexLauncher.verify(path: copy, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test func aGroupWritableFolderIsRefusedAsUnsafe() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("codex").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        #expect(chmod(copy, 0o700) == 0)
        #expect(chmod(folder.path, 0o770) == 0)
        await #expect(throws: CodexLaunchError.unsafeOwnership) {
            _ = try await CodexLauncher.verify(path: copy, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test func theDefaultRequirementRefusesAnAppleBinaryBeforeTheProbe() async {
        await #expect(throws: CodexLaunchError.signatureRejected) {
            _ = try await CodexLauncher.verify(path: "/bin/ls") { _ in
                Issue.record("probe ran for a rejected signature"); return Data()
            }
        }
    }

    @Test func anUnparseableRequirementIsRefused() async {
        await #expect(throws: CodexLaunchError.signatureRejected) {
            _ = try await CodexLauncher.verify(path: "/bin/ls", requirement: "not a requirement (",
                                               probe: Self.fixed("codex-cli 0.159.0\n"))
        }
    }

    @Test(arguments: ["codex-cli 0.158.0\n", "codex-cli 0.162.0\n", "codex-cli 0.159.0-dev\n"])
    func versionsOutsideTheExactAllowlistAreRefused(output: String) async {
        await #expect(throws: CodexLaunchError.unsupportedVersion) {
            _ = try await CodexLauncher.verify(path: "/bin/ls", requirement: Self.apple, probe: Self.fixed(output))
        }
    }

    @Test(arguments: ["", "codex-cli 0.159.0", "codex-cli 0.159.0\n\n", "codex 0.159.0\n",
                      "codex-cli \n", "codex-cli 0.159.0 extra\n", "codex-cli 0.159.0\r\n", "Codex-cli 0.159.0\n"])
    func malformedVersionOutputIsRefused(output: String) {
        #expect(throws: CodexLaunchError.versionUnavailable) { _ = try CodexLauncher.parseVersion(Data(output.utf8)) }
    }

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
            _ = try await CodexLauncher.readVersion(child, deadline: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(4))
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
    }
}
#endif
