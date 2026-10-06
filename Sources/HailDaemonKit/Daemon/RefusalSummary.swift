public import Foundation

/// Reply refusals by reason over the last 15 minutes and the last hour, from the audit log's
/// `delivery_refused` records (#247). Reasons are `LocalReplyRefusal` codes; anything else counts as `other`,
/// so the report never repeats text from the log.
public struct RefusalSummary: Codable, Sendable, Equatable {
    public struct Count: Codable, Sendable, Equatable {
        public var reason: String
        public var last15Minutes: Int
        public var lastHour: Int
    }

    /// Most frequent in the last hour first.
    public var counts: [Count]

    public var recent: [Count] { counts.filter { $0.last15Minutes > 0 } }

    /// Reads today's UTC day, and yesterday's when the hour crosses midnight, after the history verifies.
    public static func read(from history: AuditHistory, now: Date = Date()) throws -> RefusalSummary {
        let hourAgo = now.addingTimeInterval(-3_600)
        var lines = try history.today(at: now)
        if AuditChain.day(of: hourAgo) != AuditChain.day(of: now) { lines += try history.today(at: hourAgo) }
        return summarize(lines, now: now)
    }

    static func summarize(_ lines: [String], now: Date) -> RefusalSummary {
        var tally: [String: Count] = [:]
        for line in lines {
            guard let record = try? JSONDecoder().decode(AuditRecord.self, from: Data(line.utf8)),
                  record.kind == "delivery_refused", let at = timestamp(record.at),
                  case .string(let raw)? = record.fields["reason"] else { continue }
            let age = now.timeIntervalSince(at)
            guard age >= 0, age <= 3_600 else { continue }
            let reason = LocalReplyRefusal(rawValue: raw) == nil ? "other" : raw
            var count = tally[reason] ?? Count(reason: reason, last15Minutes: 0, lastHour: 0)
            count.lastHour += 1
            if age <= 900 { count.last15Minutes += 1 }
            tally[reason] = count
        }
        return .init(counts: tally.values.sorted { ($0.lastHour, $1.reason) > ($1.lastHour, $0.reason) })
    }

    private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// A plain-language fix for the most frequent recent reason.
    static func fix(for reason: String) -> String {
        switch reason {
        case LocalReplyRefusal.sourceHostMismatch.rawValue:
            "replies came from a shell with another host ID; see host_id_match"
        case LocalReplyRefusal.notUniqueRecipient.rawValue:
            "more than one device could take the reply (#230); keep one phone or tablet connected for the target"
        case LocalReplyRefusal.noRecipient.rawValue:
            "no connected device was waiting for the reply; reconnect the phone and resend the request"
        case LocalReplyRefusal.requestPending.rawValue: "a request handoff was still pending; retry the reply"
        case LocalReplyRefusal.listenerNotReady.rawValue: "the listener was not ready; see listener_ready"
        default: "check ~/Library/Logs/HailingStation/haild.err.log around those replies"
        }
    }
}
