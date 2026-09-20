import Foundation
import Testing
@testable import HailDaemonKit

/// The writer's file rules: rotation, permissions, the clock guard, the descriptor, and what this writer
/// remembers about what it wrote (#42 items 1 and 5).
@Suite struct AuditLogFileTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-audit-\(UUID().uuidString)", isDirectory: true)
    var dir: URL { scratch.appendingPathComponent("audit", isDirectory: true) }
    let day1 = Date(timeIntervalSince1970: 1_789_800_000)
    let day2 = Date(timeIntervalSince1970: 1_789_900_000)

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    @Test func aNewDayIsANewFileAndTheOldOneIsNeverRewritten() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        let firstFile = log.path(day: "2026-09-19")
        let firstBytes = try Data(contentsOf: firstFile)
        clock.now = day2
        let record = try await log.record(.denied(target: "tmux:b"))
        #expect(record.seq == 1 && record.prev != AuditChain.genesis)
        #expect(try Data(contentsOf: firstFile) == firstBytes)
        #expect(try AuditLog.verify(fileAt: log.path(day: "2026-09-20"), day: "2026-09-20").count == 2)
    }

    @Test func aSymlinkOrAWorldReadableFileIsRefused() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        await log.reset()
        let file = log.path(day: "2026-09-19")
        try #require(chmod(file.path, 0o644) == 0)
        await #expect(throws: PolicyFileError.wrongPermissions(path: file.path, mode: "644")) {
            try await AuditLog(directory: dir, now: { day1 }).record(.denied(target: "tmux:a"))
        }
        try #require(chmod(file.path, 0o600) == 0)
        let elsewhere = scratch.appendingPathComponent("elsewhere.jsonl")
        try FileManager.default.moveItem(at: file, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        await #expect(throws: PolicyFileError.wrongType(file.path)) {
            try await AuditLog(directory: dir, now: { day1 }).record(.denied(target: "tmux:a"))
        }
    }

    @Test func aFailedWriteNamesTheDayFileThatMayBeTorn() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        let file = log.path(day: "2026-09-19")
        await #expect(throws: AuditLogError.unwritable(file.path)) { try await log.write("x\n", to: -1) }
        let descriptor = await log.descriptor
        let chain = await log.chain
        #expect(descriptor == -1 && chain == nil, "closed, so the next record re-verifies")
        #expect(try await log.record(.denied(target: "tmux:b")).seq == 2)
    }

    @Test func anAppendSyncFailureIsReportedBeforeStateAdvances() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        let file = log.path(day: "2026-09-19")
        let checkpointBeforeFailure = await log.written["2026-09-19"]
        await log.setSynchronizeForTesting { _ in -1 }
        await #expect(throws: AuditLogError.unwritable(file.path)) {
            try await log.record(.denied(target: "tmux:b"))
        }
        let descriptor = await log.descriptor
        let chain = await log.chain
        let checkpointAfterFailure = await log.written["2026-09-19"]
        #expect(descriptor == -1 && chain == nil && checkpointAfterFailure == checkpointBeforeFailure)
        #expect(try AuditLog.verify(fileAt: file, day: "2026-09-19").count == 3)
    }

    @Test func aFailedDayFileDirectorySyncIsRetriedWhenTheFileExists() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        let directory = dir
        await log.setSynchronizeForTesting { descriptor in
            var descriptorInfo = stat(), directoryInfo = stat()
            let isDirectory = fstat(descriptor, &descriptorInfo) == 0
                && lstat(directory.path, &directoryInfo) == 0
                && descriptorInfo.st_dev == directoryInfo.st_dev && descriptorInfo.st_ino == directoryInfo.st_ino
            return isDirectory ? -1 : fsync(descriptor)
        }
        await #expect(throws: AuditLogError.unwritable(dir.path)) {
            try await log.record(.denied(target: "tmux:a"))
        }
        let file = log.path(day: "2026-09-19")
        #expect(FileManager.default.fileExists(atPath: file.path), "rename landed before the failed directory sync")
        await log.setSynchronizeForTesting { fsync($0) }
        #expect(try await log.record(.denied(target: "tmux:a")).seq == 1)
        #expect(try AuditLog.verify(fileAt: file, day: "2026-09-19").count == 2)
    }

    @Test func aDayFileAtCapacityRefusesFurtherAppends() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        let file = log.path(day: "2026-09-19")
        let fd = await log.descriptor
        try #require(ftruncate(fd, off_t(AuditLog.maxBytes)) == 0)  // sparse, under the open writer
        let expected = AuditLogError.fileRefused(path: file.path, reason: "day file at capacity")
        await #expect(throws: expected) { try await log.record(.denied(target: "tmux:b")) }
        let descriptor = await log.descriptor
        #expect(descriptor == -1, "the writer closed rather than growing an unverifiable file")
    }

    @Test func aClockStepBackStillFindsATailOlderThanEightDays() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        let first = log.path(day: "2026-09-19")
        let lines = try AuditLog.lines(of: try Data(contentsOf: first), path: first.path)
        for offset in 1...9 {
            clock.now = day1.addingTimeInterval(TimeInterval(offset * 86_400))
            _ = try await log.record(.denied(target: "tmux:later"))
        }
        #expect(await log.written.count == 10)
        try Data((lines.prefix(1).joined(separator: "\n") + "\n").utf8).write(to: first)
        try #require(chmod(first.path, 0o600) == 0)
        clock.now = day1  // the clock steps back to a day this writer already wrote
        let expected = AuditLogError.fileRefused(path: first.path, reason: "later day file already exists")
        await #expect(throws: expected) { try await log.record(.denied(target: "tmux:d")) }
    }

    @Test func aClockBeforeTheBuildWritesNothing() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { Date(timeIntervalSince1970: 0) })
        await #expect(throws: AuditLogError.clockBeforeBuild) { try await log.record(.denied(target: "tmux:a")) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
