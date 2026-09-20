import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct AuditDayLinkTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-audit-links-\(UUID().uuidString)", isDirectory: true)
    var dir: URL { scratch.appendingPathComponent("audit", isDirectory: true) }
    let day1 = Date(timeIntervalSince1970: 1_789_800_000)
    let day2 = Date(timeIntervalSince1970: 1_789_900_000)
    let day3 = Date(timeIntervalSince1970: 1_789_986_400)

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func first(in file: URL) throws -> AuditRecord {
        let lines = try AuditLog.lines(of: try Data(contentsOf: file), path: file.path)
        return try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
    }

    @Test func eachDayNamesTheVerifiedTailOfTheLatestEarlierDay() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        let firstFile = log.path(day: "2026-09-19")
        let firstTail = try AuditLog.verify(fileAt: firstFile, day: "2026-09-19")
        let firstOpen = try first(in: firstFile)
        #expect(firstOpen.fields["previous_day"] == .string(""))
        #expect(firstOpen.fields["previous_hash"] == .string(AuditChain.genesis))

        clock.now = day2
        _ = try await log.record(.denied(target: "tmux:b"))
        let secondOpen = try first(in: log.path(day: "2026-09-20"))
        #expect(secondOpen.fields["previous_day"] == .string("2026-09-19"))
        #expect(secondOpen.fields["previous_hash"] == .string(firstTail.lastHash))
    }

    @Test func aCorruptLatestEarlierDayIsReportedRatherThanSkipped() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        clock.now = day2
        _ = try await log.record(.denied(target: "tmux:b"))
        let secondFile = log.path(day: "2026-09-20")
        let original = try String(contentsOf: secondFile, encoding: .utf8)
        try original.replacingOccurrences(of: "tmux:b", with: "tmux:x")
            .write(to: secondFile, atomically: false, encoding: .utf8)
        try #require(chmod(secondFile.path, 0o600) == 0)
        clock.now = day3
        await #expect(throws: AuditLogError.fileRefused(
            path: secondFile.path, reason: "hashMismatch(line: 1, seq: 1)"
        )) { try await log.record(.denied(target: "tmux:c")) }
        #expect(!FileManager.default.fileExists(atPath: log.path(day: "2026-09-21").path))
    }

    @Test func deletingTheNamedPreviousDayRefusesAnExistingLaterDay() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let firstLog = AuditLog(directory: dir, now: { clock.now })
        _ = try await firstLog.record(.denied(target: "tmux:a"))
        clock.now = day2
        _ = try await firstLog.record(.denied(target: "tmux:b"))
        await firstLog.reset()
        try FileManager.default.removeItem(at: firstLog.path(day: "2026-09-19"))
        let secondFile = firstLog.path(day: "2026-09-20")
        let again = AuditLog(directory: dir, now: { day2 })
        let expected = AuditLogError.fileRefused(path: secondFile.path, reason: "previous day link does not match")
        await #expect(throws: expected) { try await again.record(.denied(target: "tmux:c")) }
    }

    @Test func aLaterDayMakesAnEarlierDayImmutableAcrossClockRollback() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        clock.now = day2
        _ = try await log.record(.denied(target: "tmux:b"))
        clock.now = day1
        let firstFile = log.path(day: "2026-09-19")
        let original = try Data(contentsOf: firstFile)
        let expected = AuditLogError.fileRefused(path: firstFile.path, reason: "later day file already exists")
        await #expect(throws: expected) { try await log.record(.denied(target: "tmux:c")) }
        #expect(try Data(contentsOf: firstFile) == original)
    }

    @Test func aLiveEarlierWriterPreventsTheNextDayFromTakingAStaleTail() async throws {
        defer { cleanUp() }
        let earlier = AuditLog(directory: dir, now: { day1 })
        _ = try await earlier.record(.denied(target: "tmux:a"))
        let later = AuditLog(directory: dir, now: { day2 })
        let firstFile = earlier.path(day: "2026-09-19")
        await #expect(throws: AuditLogError.inUse(firstFile.path)) {
            try await later.record(.denied(target: "tmux:b"))
        }
        #expect(!FileManager.default.fileExists(atPath: later.path(day: "2026-09-20").path))
    }

    @Test func aLegacyV1DayRemainsWritableAndBecomesTheNextDaysPredecessor() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var chain = AuditChain(salt: String(repeating: "a", count: 64))
        var legacy = try chain.append(.chainOpened(day: "2026-09-19"), at: day1)
        legacy.fields.removeValue(forKey: "previous_day")
        legacy.fields.removeValue(forKey: "previous_hash")
        legacy.hash = try AuditChain.hash(of: legacy)
        let firstFile = dir.appendingPathComponent("2026-09-19.jsonl")
        try (AuditChain.encodeLine(legacy) + "\n").write(to: firstFile, atomically: false, encoding: .utf8)
        try #require(chmod(firstFile.path, 0o600) == 0)

        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        let legacyTail = try AuditLog.verify(fileAt: firstFile, day: "2026-09-19")
        clock.now = day2
        _ = try await log.record(.denied(target: "tmux:b"))
        let next = try first(in: log.path(day: "2026-09-20"))
        #expect(next.fields["previous_day"] == .string("2026-09-19"))
        #expect(next.fields["previous_hash"] == .string(legacyTail.lastHash))
    }

    @Test func aDirectoryEnumerationErrorFailsClosed() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = try #require(try PolicyFile(directory: dir).openDirectory())
        defer { close(descriptor) }
        #expect(throws: AuditLogError.unwritable(dir.path)) {
            try AuditLog.directoryNames(in: descriptor, at: dir) { _ in
                errno = EIO
                return nil
            }
        }
    }
}
