import Foundation
import Testing
@testable import HailDaemonKit

/// Retained dup references model inherited open-file descriptions without forking the Swift runtime.
/// Each check happens while the duplicate is still open; closing it must not make the test pass.
@Suite struct AuditWriterLockTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-audit-lock-\(UUID().uuidString)", isDirectory: true)
    var dir: URL { scratch.appendingPathComponent("audit", isDirectory: true) }
    let day1 = Date(timeIntervalSince1970: 1_789_800_000)
    let day2 = Date(timeIntervalSince1970: 1_789_900_000)

    @Test func resetReleasesTheLockBeforeItsRetainedDuplicateCloses() async throws {
        defer { cleanUp() }
        let writer = AuditLog(directory: dir, now: { day1 })
        let before = try await writer.record(.denied(target: "tmux:a"))
        let retained = try await duplicate(writer)
        defer { close(retained) }
        await writer.reset()
        await writer.reset()  // idempotent; no old descriptor is reused
        let next = AuditLog(directory: dir, now: { day1 })
        let after = try await next.record(.denied(target: "tmux:b"))
        #expect(after.seq == 2 && after.prev == before.hash)
        await next.reset()
    }

    @Test func failedContenderResetAndDeinitDoNotUnlockTheLiveOwner() async throws {
        defer { cleanUp() }
        let owner = AuditLog(directory: dir, now: { day1 })
        _ = try await owner.record(.denied(target: "tmux:a"))
        let retained = try await duplicate(owner)
        defer { close(retained) }
        let file = owner.path(day: "2026-09-19")
        var contender: AuditLog? = AuditLog(directory: dir, now: { day1 })
        await #expect(throws: AuditLogError.inUse(file.path)) {
            try await contender?.record(.denied(target: "tmux:b"))
        }
        await contender?.reset()
        await contender?.reset()
        weak let releasedContender = contender
        contender = nil
        try #require(releasedContender == nil)
        let next = AuditLog(directory: dir, now: { day1 })
        await #expect(throws: AuditLogError.inUse(file.path)) {
            try await next.record(.denied(target: "tmux:c"))
        }
        #expect(try await owner.record(.denied(target: "tmux:d")).seq == 2)
        await owner.reset()
        #expect(try await next.record(.denied(target: "tmux:c")).seq == 3)
        await next.reset()
    }

    @Test func rotationReleasesTheRetainedPredecessorBeforeVerifyingIt() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let writer = AuditLog(directory: dir, now: { clock.now })
        let before = try await writer.record(.denied(target: "tmux:a"))
        let retained = try await duplicate(writer)
        defer { close(retained) }
        clock.now = day2
        let after = try await writer.record(.denied(target: "tmux:b"))
        let file = writer.path(day: "2026-09-20")
        let lines = try AuditLog.lines(of: Data(contentsOf: file), path: file.path)
        let opening = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        #expect(opening.fields["previous_hash"] == .string(before.hash) && after.seq == 1)
        try expectLockAvailable(writer.path(day: "2026-09-19"))
        await writer.reset()
    }

    @Test func syncFailureReleasesTheRetainedLockWithoutAdvancingItsCheckpoint() async throws {
        defer { cleanUp() }
        let writer = AuditLog(directory: dir, now: { day1 })
        _ = try await writer.record(.denied(target: "tmux:a"))
        let retained = try await duplicate(writer)
        defer { close(retained) }
        let checkpoint = await writer.written["2026-09-19"]
        let file = writer.path(day: "2026-09-19")
        await writer.setSynchronizeForTesting { _ in -1 }
        await #expect(throws: AuditLogError.unwritable(file.path)) {
            try await writer.record(.denied(target: "tmux:b"))
        }
        let descriptor = await writer.descriptor
        let afterFailure = await writer.written["2026-09-19"]
        #expect(descriptor == -1 && afterFailure == checkpoint)
        let next = AuditLog(directory: dir, now: { day1 })
        #expect(try await next.record(.denied(target: "tmux:c")).seq == 3)
        #expect(try AuditLog.verify(fileAt: file, day: "2026-09-19").count == 4)
        await next.reset()
    }

    @Test func writeFailureReleasesTheRetainedLockAndReverifies() async throws {
        defer { cleanUp() }
        let writer = AuditLog(directory: dir, now: { day1 })
        _ = try await writer.record(.denied(target: "tmux:a"))
        let retained = try await duplicate(writer)
        defer { close(retained) }
        let file = writer.path(day: "2026-09-19")
        await #expect(throws: AuditLogError.unwritable(file.path)) { try await writer.write("x\n", to: -1) }
        #expect(try await writer.record(.denied(target: "tmux:b")).seq == 2)
        await writer.reset()
    }

    @Test func capacityFailureReleasesTheRetainedLockAndStillRefusesTheFile() async throws {
        defer { cleanUp() }
        let writer = AuditLog(directory: dir, now: { day1 })
        _ = try await writer.record(.denied(target: "tmux:a"))
        let retained = try await duplicate(writer)
        defer { close(retained) }
        try #require(ftruncate(retained, off_t(AuditLog.maxBytes)) == 0)
        let file = writer.path(day: "2026-09-19")
        await #expect(throws: AuditLogError.fileRefused(path: file.path, reason: "day file at capacity")) {
            try await writer.record(.denied(target: "tmux:b"))
        }
        try expectLockAvailable(file)
        await #expect(throws: AuditLogError.fileRefused(path: file.path, reason: "torn last line")) {
            try await writer.record(.denied(target: "tmux:c"))
        }
        try expectLockAvailable(file)
    }

    @Test func verificationRefusalReleasesTheAcquiredLockAndPreservesEvidence() async throws {
        defer { cleanUp() }
        let writer = AuditLog(directory: dir, now: { day1 })
        _ = try await writer.record(.denied(target: "tmux:a"))
        let retained = try await duplicate(writer)
        defer { close(retained) }
        await writer.reset()
        let file = writer.path(day: "2026-09-19")
        let evidence = Data("torn".utf8)
        try evidence.write(to: file)
        await #expect(throws: AuditLogError.fileRefused(path: file.path, reason: "torn last line")) {
            try await writer.record(.denied(target: "tmux:b"))
        }
        try expectLockAvailable(file)
        let descriptor = await writer.descriptor
        let chain = await writer.chain
        #expect(descriptor == -1 && chain == nil)
        #expect(try Data(contentsOf: file) == evidence)
    }

    @Test func deinitReleasesTheLockBeforeItsRetainedDuplicateCloses() async throws {
        defer { cleanUp() }
        var writer: AuditLog? = AuditLog(directory: dir, now: { day1 })
        let first = try await writer?.record(.denied(target: "tmux:a"))
        try #require(first != nil)
        let retained = try await duplicate(try #require(writer))
        defer { close(retained) }
        weak let releasedWriter = writer
        writer = nil
        try #require(releasedWriter == nil, "the writer actually deinitialized before the acquisition")
        let next = AuditLog(directory: dir, now: { day1 })
        #expect(try await next.record(.denied(target: "tmux:b")).seq == 2)
        await next.reset()
    }
}

extension AuditWriterLockTests {
    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func duplicate(_ writer: AuditLog) async throws -> Int32 {
        let original = await writer.descriptor
        try #require(original >= 0)
        let retained = dup(original)
        try #require(retained >= 0)
        return retained
    }

    func expectLockAvailable(_ file: URL) throws {
        let contender = open(file.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(contender >= 0)
        defer { close(contender) }
        try #require(flock(contender, LOCK_EX | LOCK_NB) == 0)
        try #require(flock(contender, LOCK_UN) == 0)
    }
}
