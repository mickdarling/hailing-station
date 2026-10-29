import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct PolicyFileObservationTests {
    @Test(arguments: [false, true])
    func absenceIsObservedAndCreationReloads(_ directoryExists: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-absent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        if directoryExists {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let file = PolicyFile(directory: directory)
        #expect(try file.identity() == nil)
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "synthetic")])
        let registry = Registry()
        try await registry.register(adapter)
        let host = try HailHost(registry: registry, store: file)
        #expect(await host.refreshedPolicy() == Policy())
        #expect(await host.policyFailure == nil)
        let absent: TargetPolicyGeneration = await host.inputPolicyGeneration(for: "tmux:a")
        #expect(!absent.wasGranted)
        #expect(throws: HostError.denied(.notAllowed("tmux:a"))) { try absent.requireCurrent() }
        await #expect(throws: HostError.denied(.notAllowed("tmux:a"))) {
            try await host.send("synthetic", to: "tmux:a")
        }
        await #expect(throws: HostError.denied(.notAllowed("tmux:a"))) {
            try await host.sendAuthorized("synthetic", policyGeneration: absent, from: "test",
                                          expectedBinding: nil, context: nil)
        }
        var policy = Policy()
        try policy.allow("tmux:a", binding: "synthetic", tier: .open)
        try file.save(policy)
        absent.observePolicy()
        #expect(try file.identity() != nil)
        #expect(host.targetPolicy.snapshot(for: "tmux:a").wasGranted)
        #expect(!absent.wasGranted)
    }

    @Test func absentFileStillChecksDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-absent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = PolicyFile(directory: directory)
        #expect(try file.identity() == nil)
        try #require(chmod(directory.path, 0o750) == 0)
        #expect(throws: PolicyFileError.wrongPermissions(path: directory.path, mode: "750")) {
            try file.identity()
        }
    }

    @Test(arguments: ["symlink", "directory", "permissions", "unreadable"])
    func untrustedFileIsUnavailableInsteadOfAbsent(_ failure: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-untrusted-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PolicyFile(directory: directory)
        try file.save(Policy())
        switch failure {
        case "symlink":
            try FileManager.default.removeItem(at: file.path)
            try FileManager.default.createSymbolicLink(at: file.path,
                                                      withDestinationURL: directory.appendingPathComponent("absent"))
        case "directory":
            try FileManager.default.removeItem(at: file.path)
            try FileManager.default.createDirectory(at: file.path, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        default:
            try #require(chmod(file.path.path, failure == "unreadable" ? 0o000 : 0o644) == 0)
        }
        #expect(throws: PolicyFileError.self) { try file.identity() }
        let host = try HailHost(registry: Registry(), store: file)
        #expect(await host.refreshedPolicy() == nil)
        #expect(await host.policyFailure != nil)
    }

    @Test func identityTracksInodeNanosecondMtimeAndSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PolicyFile(directory: directory)
        try file.save(Policy())
        let original: PolicyFileIdentity = try #require(try file.identity())
        var metadata = stat()
        try #require(lstat(file.path.path, &metadata) == 0)
        let access = metadata.st_atimespec
        let modified = metadata.st_mtimespec
        var times = [access, timespec(tv_sec: modified.tv_sec, tv_nsec: (modified.tv_nsec + 1) % 1_000_000_000)]
        try #require(utimensat(AT_FDCWD, file.path.path, &times, 0) == 0)
        let touched: PolicyFileIdentity = try #require(try file.identity())
        #expect(touched.inode == original.inode)
        #expect(touched.size == original.size)
        #expect(touched.modified != original.modified)
        let content = try Data(contentsOf: file.path)
        try (content + Data(" ".utf8)).write(to: file.path)
        times = [access, modified]
        try #require(utimensat(AT_FDCWD, file.path.path, &times, 0) == 0)
        let resized: PolicyFileIdentity = try #require(try file.identity())
        #expect(resized.inode == original.inode)
        #expect(resized.modified == original.modified)
        #expect(resized.size == original.size + 1)
        let replacement = directory.appendingPathComponent("replacement")
        try content.write(to: replacement)
        try #require(chmod(replacement.path, 0o600) == 0)
        try #require(utimensat(AT_FDCWD, replacement.path, &times, 0) == 0)
        try #require(rename(replacement.path, file.path.path) == 0)
        let replaced: PolicyFileIdentity = try #require(try file.identity())
        #expect(replaced.inode != original.inode)
        #expect(replaced.modified == original.modified)
        #expect(replaced.size == original.size)
    }

    @Test func unchangedSegmentsDoNotReadPolicyAgain() async throws {
        let rig = try await AmbientPolicyRig.make()
        let before: Int = rig.store.loads
        let first: HostSessionResult = await rig.segment(1)
        let second: HostSessionResult = await rig.segment(2)
        let after: Int = rig.store.loads
        #expect(first.frames.isEmpty)
        #expect(second.frames.isEmpty)
        #expect(after == before)
        try await rig.write(.deny, target: "tmux:b", externally: true)
        let changed: HostSessionResult = await rig.segment(3)
        let reloaded: Int = rig.store.loads
        #expect(changed.frames.isEmpty)
        #expect(reloaded == before + 1)
        #expect(rig.sink.segments == [0, 1, 2, 3])
    }
}
