#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Synthetic only: system binaries for signature checks, invented scripts for the version probe.
/// No real Codex binary, account, thread or inference is used.
@Suite struct CodexLauncherTests {
    static let apple = "anchor apple"
    static func fixed(_ text: String) -> @Sendable (String) async throws -> Data {
        { _ in Data(text.utf8) }
    }
    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-launcher-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }
    static func script(_ body: String, in folder: URL) throws -> String {
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

    @Test(arguments: [("bin/ls", CodexLaunchError.invalidPath), ("", .invalidPath),
                      ("/nonexistent-synthetic/codex", .invalidPath), ("/bin", .notExecutable)])
    func relativeMissingOrNonFilePathsAreRefused(path: String, refusal: CodexLaunchError) async {
        await #expect(throws: refusal) {
            _ = try await CodexLauncher.verify(path: path, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test func anExecutableThatIsNotMachOIsRefused() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try Self.script(String(repeating: "\u{7f}ELF invented bytes ", count: 8), in: folder)
        await #expect(throws: CodexLaunchError.notExecutable) {
            _ = try await CodexLauncher.verify(path: path, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test func theDefaultRequirementDemandsDeveloperIDMarkersAndOpenAITeam() {
        let requirement = CodexLauncher.defaultRequirement
        #expect(requirement.contains(#"identifier "codex""#))
        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "2DC432GLL2""#))
    }

    @Test func aProbeThatCannotSpawnIsAFixedVersionRefusal() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try Self.script("#!/bin/sh\necho 'codex-cli 0.159.0'\n", in: folder)
        #expect(chmod(path, 0o600) == 0)
        await #expect(throws: CodexLaunchError.versionUnavailable) { _ = try await CodexLauncher.readVersion(path) }
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

    @Test(arguments: [false, true]) func anExtendedACLOnTheBinaryOrFolderIsRefused(onFolder: Bool) async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("codex").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        #expect(chmod(copy, 0o700) == 0)
        let chmodACL = Process()
        chmodACL.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodACL.arguments = ["+a", "everyone allow write", onFolder ? folder.path : copy]
        try chmodACL.run(); chmodACL.waitUntilExit()
        #expect(chmodACL.terminationStatus == 0)
        await #expect(throws: CodexLaunchError.unsafeOwnership) {
            _ = try await CodexLauncher.verify(path: copy, requirement: Self.apple, probe: Self.fixed(""))
        }
    }

    @Test func aGroupWritableAncestorIsRefusedAsUnsafe() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inner = folder.appendingPathComponent("outer/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let copy = inner.appendingPathComponent("codex").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        #expect(chmod(copy, 0o700) == 0 && chmod(inner.path, 0o700) == 0)
        #expect(chmod(folder.appendingPathComponent("outer").path, 0o777) == 0)
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
}
#endif
