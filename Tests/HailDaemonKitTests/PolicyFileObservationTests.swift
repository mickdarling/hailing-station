import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct PolicyFileObservationTests {
    @Test func identityTracksInodeNanosecondMtimeAndSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PolicyFile(directory: directory)
        try file.save(Policy())
        let original: PolicyFileIdentity = try file.identity()
        var metadata = stat()
        try #require(lstat(file.path.path, &metadata) == 0)
        let access = metadata.st_atimespec
        let modified = metadata.st_mtimespec
        var times = [access, timespec(tv_sec: modified.tv_sec, tv_nsec: (modified.tv_nsec + 1) % 1_000_000_000)]
        try #require(utimensat(AT_FDCWD, file.path.path, &times, 0) == 0)
        let touched: PolicyFileIdentity = try file.identity()
        #expect(touched.inode == original.inode)
        #expect(touched.size == original.size)
        #expect(touched.modified != original.modified)
        let content = try Data(contentsOf: file.path)
        try (content + Data(" ".utf8)).write(to: file.path)
        times = [access, modified]
        try #require(utimensat(AT_FDCWD, file.path.path, &times, 0) == 0)
        let resized: PolicyFileIdentity = try file.identity()
        #expect(resized.inode == original.inode)
        #expect(resized.modified == original.modified)
        #expect(resized.size == original.size + 1)
        let replacement = directory.appendingPathComponent("replacement")
        try content.write(to: replacement)
        try #require(chmod(replacement.path, 0o600) == 0)
        try #require(utimensat(AT_FDCWD, replacement.path, &times, 0) == 0)
        try #require(rename(replacement.path, file.path.path) == 0)
        let replaced: PolicyFileIdentity = try file.identity()
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
