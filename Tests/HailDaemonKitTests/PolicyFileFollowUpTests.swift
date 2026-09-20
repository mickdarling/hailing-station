import Foundation
import Testing
@testable import HailDaemonKit

/// Persistence races and post-rename durability semantics tracked by #87.
@Suite struct PolicyFileFollowUpTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-policy-follow-up-\(UUID().uuidString)", isDirectory: true)

    var dir: URL { scratch.appendingPathComponent("hail", isDirectory: true) }
    var file: PolicyFile { PolicyFile(directory: dir) }

    func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info.st_mode & 0o777
    }

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func samplePolicy() throws -> Policy {
        var policy = Policy(deliveriesPerMinute: 12)
        try policy.allow("tmux:a", binding: "$1@1/%1:9", tier: .open, capture: true)
        return policy
    }

    @Test func saveUnconditionallyWritesAnEmptyPolicyAndRepairsMalformedJSON() throws {
        defer { cleanUp() }
        try file.save(Policy())
        #expect(FileManager.default.fileExists(atPath: file.path.path))
        #expect(try file.load() == Policy())

        try Data("not json".utf8).write(to: file.path)
        try #require(chmod(file.path.path, 0o600) == 0)
        try file.save(Policy(deliveriesPerMinute: 7))
        #expect(try file.load().deliveriesPerMinute == 7)

        let invalid = Policy(guardPatterns: [GuardPattern(name: "bad", regex: "[")])
        #expect(throws: PolicyFormatError.invalidGuardPattern("bad")) { try file.save(invalid) }
        #expect(try file.load().deliveriesPerMinute == 7)
    }

    @Test func aConcurrentFirstRunDirectoryCreationToleratesEEXISTThenChecksTheDirectory() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var raced = false
        try file.createDirectoryIfMissing(makeDirectory: { descriptor, name, mode in
            if !raced {
                raced = true
                let result = mkdirat(descriptor, name, mode)
                if result != 0 { return result }
                errno = EEXIST
                return -1
            }
            return mkdirat(descriptor, name, mode)
        })
        #expect(raced)
        #expect(try mode(dir) == 0o700)
    }

    @Test func aHeldWriterLockFailsWithinTheBoundedWait() throws {
        defer { cleanUp() }
        try file.save(try samplePolicy())
        let opened = try file.openDirectory()
        let held = try #require(opened)
        defer { close(held) }
        try #require(flock(held, LOCK_EX) == 0)
        defer { flock(held, LOCK_UN) }

        var waits = 0
        #expect(throws: PolicyFileError.busy(dir.path)) {
            try file.update(
                synchronizeDirectory: { fsync($0) },
                waitBetweenAttempts: { _ in waits += 1 },
                { $0.deny("tmux:a") }
            )
        }
        #expect(waits == PolicyFile.lockAttempts - 1)
        #expect(try file.load().targets.keys.sorted() == ["tmux:a"])
    }

    @Test func aDirectorySyncFailureReportsUncertainDurabilityAfterTheRename() throws {
        defer { cleanUp() }
        try file.save(try samplePolicy())
        let update = try file.update(
            synchronizeDirectory: { _ in
                errno = EIO
                return -1
            },
            { $0.deny("tmux:a") }
        )
        #expect(update.policy.targets.isEmpty)
        #expect(update.durabilityFailure == .unwritable("\(dir.path): Input/output error"))
        #expect(try file.load().targets.isEmpty, "the renamed policy is already what readers see")
    }
}
