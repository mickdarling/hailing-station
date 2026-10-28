#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct CodexRecoveryConfigurationTests {
    func bundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("node_modules/ws"),
                                                withIntermediateDirectories: true)
        for name in ["run.py", "host.cjs", "index.cjs", "node_modules/ws/package.json"] {
            try Data("{}".utf8).write(to: bundle.appendingPathComponent(name))
        }
        return bundle
    }
    @Test func protectedManifestPinsExistingProfileAndFixedWorkerCommand() throws {
        let root = FakeRightyo.physical(FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-config-\(UUID())"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profile.json"), manifest = root.appendingPathComponent("host.json")
        func write(_ url: URL, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: url)
            #expect(chmod(url.path, 0o600) == 0)
        }
        try write(profile, ["version": 1, "target": "tmux:authored", "binding": "pinned"])
        let bundle = try bundle(in: root)
        let value: [String: Any] = ["version": 1, "profile": profile.path,
            "runner": bundle.appendingPathComponent("run.py").path, "python": "/usr/bin/true", "node": "/usr/bin/true"]
        try write(manifest, value)
        let config = try CodexRecoveryConfiguration.load(manifest)
        #expect(config.target == "tmux:authored" && config.binding == "pinned")
        #expect(config.command.arguments.contains("host"))
        #expect(config.command.environment.contains("WS_NO_BUFFER_UTIL=1"))
        #expect(config.command.environment.contains("WS_NO_UTF_8_VALIDATE=1"))
        #expect(config.command.arguments.contains(profile.path))
        try refusesUnsafeResources(root: root, bundle: bundle, manifest: manifest, value: value)
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
    func refusesUnsafeResources(root: URL, bundle: URL, manifest: URL, value: [String: Any]) throws {
        let nested = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let moved = nested.appendingPathComponent("host.json")
        try JSONSerialization.data(withJSONObject: value).write(to: moved)
        #expect(chmod(moved.path, 0o600) == 0)
        #expect(chmod(root.path, 0o777) == 0)
        #expect(throws: CodexRecoveryFault.unavailable) { try CodexRecoveryConfiguration.load(moved) }
        #expect(chmod(root.path, 0o700) == 0)
        let delegated = bundle.appendingPathComponent("host.cjs")
        #expect(chmod(delegated.path, 0o666) == 0)
        #expect(throws: CodexRecoveryFault.unavailable) { try CodexRecoveryConfiguration.load(manifest) }
        #expect(chmod(delegated.path, 0o644) == 0)
        let elsewhere = root.appendingPathComponent("relocated")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let module = elsewhere.appendingPathComponent("host.cjs")
        try Data("{}".utf8).write(to: module)
        let unsafe = elsewhere.appendingPathComponent("index.cjs")
        try Data("{}".utf8).write(to: unsafe)
        #expect(chmod(unsafe.path, 0o666) == 0)
        try FileManager.default.removeItem(at: delegated)
        try FileManager.default.createSymbolicLink(at: delegated, withDestinationURL: module)
        #expect(throws: CodexRecoveryFault.unavailable) { try CodexRecoveryConfiguration.load(manifest) }
    }
}
#endif
