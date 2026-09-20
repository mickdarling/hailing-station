import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct AuditHistoryTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-audit-history-\(UUID().uuidString)", isDirectory: true)
    var dir: URL { scratch.appendingPathComponent("audit", isDirectory: true) }
    let day1 = Date(timeIntervalSince1970: 1_789_800_000)
    let day2 = Date(timeIntervalSince1970: 1_789_900_000)
    let day3 = Date(timeIntervalSince1970: 1_789_986_400)

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func writeLegacy(day: String, at date: Date) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try #require(chmod(dir.path, 0o700) == 0)
        var chain = AuditChain(salt: String(repeating: "a", count: 64))
        var record = try chain.append(.chainOpened(day: day), at: date)
        record.fields.removeValue(forKey: "previous_day")
        record.fields.removeValue(forKey: "previous_hash")
        record.hash = try AuditChain.hash(of: record)
        let file = dir.appendingPathComponent("\(day).jsonl")
        try (AuditChain.encodeLine(record) + "\n").write(to: file, atomically: false, encoding: .utf8)
        try #require(chmod(file.path, 0o600) == 0)
    }

    @Test func verifiesLinkedDaysAndSuppliesTailAndToday() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        for index in 0..<6 { _ = try await log.record(.denied(target: "tmux:a\(index)")) }
        clock.now = day2
        for index in 0..<6 { _ = try await log.record(.denied(target: "tmux:b\(index)")) }
        try Data("ignored".utf8).write(to: dir.appendingPathComponent(".2026-09-20.jsonl.dead.tmp"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes"))

        let history = AuditHistory(directory: dir)
        let report = try history.verify()
        let expectedTail = try AuditLog.verify(
            fileAt: log.path(day: "2026-09-20"), day: "2026-09-20"
        )
        #expect(report.days == 2 && report.records == 14 && report.lastDay == "2026-09-20")
        #expect(report.lastHash == expectedTail.lastHash)
        let tail = try history.tail()
        #expect(tail.count == 10)
        #expect(tail.last?.contains("tmux:b5") == true)
        let today = try history.today(at: day2)
        #expect(today.count == 7 && today[0].contains("chain_opened") && today.last?.contains("tmux:b5") == true)
    }

    @Test func deletionOfAnIntermediateDayBreaksTheNextLink() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        clock.now = day2
        _ = try await log.record(.denied(target: "tmux:b"))
        clock.now = day3
        _ = try await log.record(.denied(target: "tmux:c"))
        await log.reset()
        try FileManager.default.removeItem(at: log.path(day: "2026-09-20"))

        let last = log.path(day: "2026-09-21")
        #expect(throws: AuditLogError.fileRefused(path: last.path, reason: "previous day link does not match")) {
            try AuditHistory(directory: dir).verify()
        }
    }

    @Test func legacyFilesAreOnlyAcceptedAsAnInitialPrefix() async throws {
        defer { cleanUp() }
        let clock = ClockBox(day1)
        let log = AuditLog(directory: dir, now: { clock.now })
        _ = try await log.record(.denied(target: "tmux:a"))
        await log.reset()
        try writeLegacy(day: "2026-09-20", at: day2)

        let file = dir.appendingPathComponent("2026-09-20.jsonl")
        #expect(throws: AuditLogError.fileRefused(path: file.path, reason: "legacy day follows linked history")) {
            try AuditHistory(directory: dir).verify()
        }
    }

    @Test func aLegacyPrefixCanCutOverToLinkedDays() async throws {
        defer { cleanUp() }
        try writeLegacy(day: "2026-09-19", at: day1)
        let log = AuditLog(directory: dir, now: { day2 })
        _ = try await log.record(.denied(target: "tmux:b"))
        let report = try AuditHistory(directory: dir).verify()
        #expect(report.days == 2 && report.records == 3 && report.lastDay == "2026-09-20")
    }

    @Test func aTornReadIsRetriedOnceWithoutTakingTheWritersLock() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        let file = log.path(day: "2026-09-19")
        let complete = try Data(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{".utf8))
        try handle.close()
        var retries = 0

        let result = try AuditHistory(directory: dir).scan(retry: {
            retries += 1
            try? complete.write(to: file, options: [])
            _ = chmod(file.path, 0o600)
        })
        #expect(retries == 1 && result.report.records == 2)
    }

    @Test func aFileThatGrowsDuringTheReadIsReopenedOnce() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        let file = log.path(day: "2026-09-19")
        let lines = try AuditLog.lines(of: Data(contentsOf: file), path: file.path)
        let first = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        let tail = try AuditChain.verify(lines: lines)
        var chain = try AuditChain(continuing: tail, first: first)
        let next = try chain.append(.denied(target: "tmux:b"), at: day1)
        let addition = Data((try AuditChain.encodeLine(next) + "\n").utf8)
        var retries = 0

        let result = try AuditHistory(directory: dir).scan(
            retry: { retries += 1 },
            afterRead: { attempt in
                guard attempt == 0 else { return }
                let handle = try? FileHandle(forWritingTo: file)
                _ = try? handle?.seekToEnd()
                try? handle?.write(contentsOf: addition)
                try? handle?.close()
            }
        )
        #expect(retries == 1 && result.report.records == 3)
    }

    @Test func aMissingOrEmptyAuditDirectoryIsNotReportedAsVerified() throws {
        defer { cleanUp() }
        let history = AuditHistory(directory: dir)
        #expect(AuditHistory.standard(environment: ["HAIL_CONFIG_DIR": scratch.path]).directory == dir)
        #expect(throws: AuditHistoryError.noHistory(dir.path)) { try history.verify() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #expect(throws: AuditHistoryError.noHistory(dir.path)) { try history.verify() }
    }

    @Test func aSuspiciousJsonlNameFailsClosedWhileDotfilesAreSkipped() async throws {
        defer { cleanUp() }
        let log = AuditLog(directory: dir, now: { day1 })
        _ = try await log.record(.denied(target: "tmux:a"))
        try Data().write(to: dir.appendingPathComponent(".recovery.jsonl"))
        #expect(try AuditHistory(directory: dir).verify().days == 1)
        let suspicious = dir.appendingPathComponent("latest-copy.jsonl")
        try Data().write(to: suspicious)
        #expect(throws: AuditLogError.fileRefused(
            path: suspicious.path, reason: "invalid audit day filename"
        )) { try AuditHistory(directory: dir).verify() }
    }
}
