import Foundation
import Testing
@testable import HailDaemonKit

/// The day files (#42 items 1 and 5): private, append-only, verified before they are continued, one per
/// UTC day, refused when tampered or mislabelled.
@Suite struct AuditLogTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-audit-\(UUID().uuidString)", isDirectory: true)
    var dir: URL { scratch.appendingPathComponent("audit", isDirectory: true) }
    let day1 = Date(timeIntervalSince1970: 1_789_800_000)  // 2026-09-19T06:40:00Z
    let day2 = Date(timeIntervalSince1970: 1_789_900_000)  // 2026-09-20T10:26:40Z

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info.st_mode & 0o777
    }

    @Test func aDayFileStartsWithItsChainAndIsPrivate() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        let record = try await log.record(.denied(target: "tmux:a"))
        #expect(record.seq == 1, "chain_opened came first")
        let file = log.path(day: "2026-09-19")
        #expect(try mode(dir) == 0o700 && mode(file) == 0o600)
        let tail = try AuditLog.verify(fileAt: file, day: "2026-09-19")
        #expect(tail == AuditChain.Tail(count: 2, lastHash: record.hash))
        let lines = try AuditLog.lines(of: try Data(contentsOf: file), path: file.path)
        #expect(lines.count == 2 && lines[0].contains("\"day\":\"2026-09-19\""))
    }

    @Test func restartingContinuesTheVerifiedChain() async throws {
        defer { cleanUp() }
        let first = AuditLog(directory: dir, now: { day1 })
        let before = try await first.record(.denied(target: "tmux:a"))
        await first.reset()  // the process that held the file is gone
        let second = AuditLog(directory: dir, now: { day1 })
        let after = try await second.record(.allowed(target: "tmux:a", tier: "open", capture: false))
        #expect(after.seq == 2 && after.prev == before.hash)
        let file = second.path(day: "2026-09-19")
        #expect(try AuditLog.verify(fileAt: file, day: "2026-09-19").count == 3)
        let lines = try AuditLog.lines(of: try Data(contentsOf: file), path: file.path)
        let salts = try lines.map { try JSONDecoder().decode(AuditRecord.self, from: Data($0.utf8)) }
        #expect(salts.filter { $0.kind == "chain_opened" }.count == 1, "no second open on restart")
    }

    @Test func aTamperedOrMislabelledFileIsRefusedAndLeftAlone() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        await log.reset()
        let file = log.path(day: "2026-09-19")
        let original = try String(contentsOf: file, encoding: .utf8)
        let edited = original.replacingOccurrences(of: "tmux:a", with: "tmux:b")
        try edited.write(to: file, atomically: false, encoding: .utf8)
        try #require(chmod(file.path, 0o600) == 0)
        let again = AuditLog(directory: dir, now: { day1 })
        let expected = AuditLogError.fileRefused(path: file.path, reason: "hashMismatch(line: 1, seq: 1)")
        await #expect(throws: expected) { try await again.record(.denied(target: "tmux:c")) }
        #expect(try String(contentsOf: file, encoding: .utf8) == edited, "evidence is not overwritten")
        await #expect(throws: expected) { try await again.record(.denied(target: "tmux:c")) }
        try original.write(to: file, atomically: false, encoding: .utf8)
        try #require(chmod(file.path, 0o600) == 0)
        let repaired = try await again.record(.denied(target: "tmux:c"))
        #expect(repaired.seq == 2, "a refused writer retries from scratch on the next record")

        let other = log.path(day: "2026-09-20")
        try original.write(to: other, atomically: false, encoding: .utf8)  // a day file under another name
        try #require(chmod(other.path, 0o600) == 0)
        #expect(throws: AuditLogError.fileRefused(path: other.path, reason: "chain_opened names another day")) {
            try AuditLog.verify(fileAt: other, day: "2026-09-20")
        }
        await again.reset()
        let onDay2 = AuditLog(directory: dir, now: { day2 })
        await #expect(throws: AuditLogError.fileRefused(path: other.path, reason: "chain_opened names another day")) {
            try await onDay2.record(.denied(target: "tmux:c"))
        }
    }

    @Test func aTornEmptyOrUndecodableFileIsRefusedNotAppendedTo() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        await log.reset()
        let file = log.path(day: "2026-09-19")
        let whole = try Data(contentsOf: file)
        for (bytes, reason) in [
            (whole.dropLast(3), "torn last line"),
            (Data(), "empty day file"),
            (Data([0xFF, 0xFE, 0x0A]), "not UTF-8")
        ] {
            try Data(bytes).write(to: file)
            try #require(chmod(file.path, 0o600) == 0)
            let again = AuditLog(directory: dir, now: { day1 })
            await #expect(throws: AuditLogError.fileRefused(path: file.path, reason: reason)) {
                try await again.record(.denied(target: "tmux:b"))
            }
            #expect(try Data(contentsOf: file) == Data(bytes), "nothing appended after \(reason)")
            await again.reset()
            #expect(throws: AuditLogError.fileRefused(path: file.path, reason: reason)) {
                try AuditLog.verify(fileAt: file, day: "2026-09-19")
            }
        }
    }

    @Test func theWriterAppendsThroughOneCheckedDescriptor() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        let fd = await log.descriptor
        #expect(fd >= 0 && fcntl(fd, F_GETFL) & O_APPEND != 0, "every write lands at the end")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["2026-09-19.jsonl"], "no temp left")
    }

    @Test func aFileShorterThanWhatThisWriterWroteIsRefused() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        _ = try await log.record(.denied(target: "tmux:b"))
        let file = log.path(day: "2026-09-19")
        let whole = try Data(contentsOf: file)
        let lines = try AuditLog.lines(of: whole, path: file.path)
        await log.reset()  // the writer keeps what it wrote even when the file is closed
        try Data((lines.prefix(2).joined(separator: "\n") + "\n").utf8).write(to: file)
        try #require(chmod(file.path, 0o600) == 0)
        #expect(try AuditLog.verify(fileAt: file, day: "2026-09-19").count == 2, "a clean prefix verifies alone")
        let expected = AuditLogError.fileRefused(path: file.path, reason: "not what this writer wrote")
        await #expect(throws: expected) { try await log.record(.denied(target: "tmux:c")) }
        // Same length, different tail: also not what this writer wrote.
        var forged = lines
        forged[2] = forged[2].replacingOccurrences(of: "tmux:b", with: "tmux:x")
        try Data((forged.joined(separator: "\n") + "\n").utf8).write(to: file)
        try #require(chmod(file.path, 0o600) == 0)
        await #expect(throws: AuditLogError.self) { try await log.record(.denied(target: "tmux:c")) }
        // A replaced file (another chain) is the operator's decision: it starts over.
        try FileManager.default.removeItem(at: file)
        let fresh = try await log.record(.denied(target: "tmux:c"))
        #expect(fresh.seq == 1)
    }

    @Test func aDayFileOverTheCapIsRefusedBeforeItIsRead() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        await log.reset()
        let file = log.path(day: "2026-09-19")
        try #require(truncate(file.path, off_t(AuditLog.maxBytes + 1)) == 0)  // sparse, nothing is read
        #expect(throws: AuditLogError.fileRefused(path: file.path, reason: "over 256 MiB")) {
            try AuditLog.verify(fileAt: file, day: "2026-09-19")
        }
        let missing = log.path(day: "2026-09-18")
        #expect(throws: AuditLogError.fileRefused(path: missing.path, reason: "no such file")) {
            try AuditLog.verify(fileAt: missing, day: "2026-09-18")
        }
    }

    @Test func oneWriterPerDayFile() async throws {
        defer { cleanUp() }
        let first = AuditLog(directory: dir, now: { day1 })
        _ = try await first.record(.denied(target: "tmux:a"))
        let second = AuditLog(directory: dir, now: { day1 })
        let file = first.path(day: "2026-09-19")
        await #expect(throws: AuditLogError.inUse(file.path)) { try await second.record(.denied(target: "tmux:b")) }
        #expect(try AuditLog.verify(fileAt: file, day: "2026-09-19").count == 2)
        await first.reset()
        #expect(try await second.record(.denied(target: "tmux:b")).seq == 2, "released when the first lets go")
    }
}

final class ClockBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
