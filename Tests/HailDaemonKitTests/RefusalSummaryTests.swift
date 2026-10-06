import Foundation
import Testing
@testable import HailDaemonKit

/// Reply refusal counts for `haild doctor` (#247), from `delivery_refused` audit records.
@Suite struct RefusalSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ kind: String = "delivery_refused", reason: String, minutesAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record: [String: Any] = [
            "version": 1, "seq": 1, "at": formatter.string(from: now.addingTimeInterval(-minutesAgo * 60)),
            "kind": kind, "fields": ["reason": reason, "target": "t", "device": "local-reply"],
            "untrusted": ["reason", "target"], "prev": "0", "hash": "0"
        ]
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    @Test func countsByReasonInTheFifteenMinuteAndHourWindows() {
        let summary = RefusalSummary.summarize([
            line(reason: "notUniqueRecipient", minutesAgo: 1),
            line(reason: "notUniqueRecipient", minutesAgo: 30),
            line(reason: "noRecipient", minutesAgo: 59),
            line(reason: "noRecipient", minutesAgo: 61),
            line("pushed", reason: "noRecipient", minutesAgo: 1),
            "not json"
        ], now: now)
        #expect(summary.counts == [
            .init(reason: "notUniqueRecipient", last15Minutes: 1, lastHour: 2),
            .init(reason: "noRecipient", last15Minutes: 0, lastHour: 1)
        ])
        #expect(summary.recent.map(\.reason) == ["notUniqueRecipient"])
    }

    @Test func unknownReasonsNeverRepeatLogText() {
        let summary = RefusalSummary.summarize([line(reason: "free text from somewhere", minutesAgo: 2)], now: now)
        #expect(summary.counts == [.init(reason: "other", last15Minutes: 1, lastHour: 1)])
    }

    @Test func recentRefusalsFailWithTheFixForTheMostFrequentReason() throws {
        let cli = HealthReport.CLI(version: "0.1.0", build: "a", hostID: "h")
        let daemon = DaemonStatus(
            schema: DaemonStatus.currentSchema, version: "0.1.0", build: "a", pid: 1, startedAt: now, updatedAt: now,
            hostID: "h", listener: .init(state: "ready", endpoint: "127.0.0.1:18765"), connectedSessions: 1
        )
        let busy = RefusalSummary.summarize([
            line(reason: "noRecipient", minutesAgo: 2),
            line(reason: "notUniqueRecipient", minutesAgo: 3),
            line(reason: "notUniqueRecipient", minutesAgo: 4)
        ], now: now)
        let report = HealthReport.evaluate(cli: cli, daemon: daemon, refusals: busy, isRunning: { _ in true })
        let check = try #require(report.checks.first { $0.name == "recent_refusals" })
        #expect(check.outcome == .fail && check.fix?.contains("#230") == true)
        let quiet = RefusalSummary.summarize([line(reason: "noRecipient", minutesAgo: 40)], now: now)
        let calm = HealthReport.evaluate(cli: cli, daemon: daemon, refusals: quiet, isRunning: { _ in true })
        #expect(calm.healthy && calm.checks.last?.detail == "none in 15 min, 1 in the last hour")
        #expect(HealthReport.evaluate(cli: cli, daemon: daemon, isRunning: { _ in true })
            .checks.allSatisfy { $0.name != "recent_refusals" })
    }
}
