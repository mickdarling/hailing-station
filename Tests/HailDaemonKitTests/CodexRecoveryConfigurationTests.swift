#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct CodexRecoveryConfigurationTests {
    @Test func protectedManifestPinsExistingProfileAndFixedWorkerCommand() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("recovery-config-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profile.json"), manifest = root.appendingPathComponent("host.json")
        func write(_ url: URL, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: url)
            #expect(chmod(url.path, 0o600) == 0)
        }
        try write(profile, ["version": 1, "target": "tmux:authored", "binding": "pinned"])
        let value: [String: Any] = ["version": 1, "profile": profile.path, "runner": "/usr/bin/true",
                                   "python": "/usr/bin/true", "node": "/usr/bin/true"]
        try write(manifest, value)
        let config = try CodexRecoveryConfiguration.load(manifest)
        #expect(config.target == "tmux:authored" && config.binding == "pinned")
        #expect(config.command.arguments.contains("host"))
        #expect(config.command.arguments.contains(profile.path))
        #expect(chmod(profile.path, 0o644) == 0)
        #expect(throws: CodexRecoveryFault.unavailable) { try CodexRecoveryConfiguration.load(manifest) }
        #expect(chmod(profile.path, 0o600) == 0)
        #expect(chmod(root.path, 0o755) == 0)
        #expect(throws: CodexRecoveryFault.unavailable) { try CodexRecoveryConfiguration.load(manifest) }
        #expect(chmod(root.path, 0o700) == 0)
        try FileManager.default.removeItem(at: profile)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: manifest)
        #expect(throws: CodexRecoveryFault.unavailable) { try CodexRecoveryConfiguration.load(manifest) }
    }
}
#endif
