import Foundation
import Testing
@testable import HailDaemonKit

/// Every event type produces a record that parses and verifies, and every external string is cleaned
/// and marked (#42 items 2 and 5, threat model B3 log injection).
@Suite struct AuditCoverageTests {
    let date = Date(timeIntervalSince1970: 1_789_800_000)

    /// One of every case; a new case must be added here or the kinds assertion below fails.
    static let everyEvent: [AuditEvent] = [
        .chainOpened(day: "2026-09-19"),
        .paired(device: AuditDevice(name: "ipad", keyID: "k1")), .revoked(device: "ipad"), .rotated(keyID: "k1"),
        .connected(device: "ipad"), .disconnected(device: "ipad", reason: "closed"),
        .allowed(target: "tmux:a", tier: "confirm", capture: true), .denied(target: "tmux:a"),
        .tierChanged(target: "tmux:a", tier: "open"),
        .delivered(target: "tmux:a", device: "ipad", text: "ls", confirmed: true, guardHits: ["sudo"], stripped: 2),
        .deliveryRefused(target: "tmux:a", device: "ipad", reason: "locked"),
        .captured(target: "tmux:a", device: "ipad"), .pushed(tool: "vbsay", target: "tmux:a", bytes: 12),
        .lockdown(on: true, reason: "five failed handshakes"), .doctorFailed(check: "bind", reason: "0.0.0.0")
    ]

    @Test func everyEventTypeProducesARecordThatVerifies() throws {
        var chain = AuditChain()
        var lines: [String] = []
        for event in Self.everyEvent {
            let record = try chain.append(event, at: date)
            #expect(!record.fields.isEmpty, "\(event.kind) stores something")
            lines.append(try AuditChain.encodeLine(record))
        }
        #expect(try AuditChain.verify(lines: lines).count == Self.everyEvent.count)
        #expect(Set(Self.everyEvent.map(\.kind)) == AuditEvent.kinds, "every kind verify accepts is produced here")
        let paired = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[1].utf8))
        #expect(paired.fields["device_key"] == .string("k1") && paired.untrusted == ["device"])
        let kinds = Set(Self.everyEvent.map(\.kind))
        #expect(kinds.count == Self.everyEvent.count, "kinds are distinct")
        #expect(kinds == [
            "chain_opened", "paired", "revoked", "rotated", "connected", "disconnected", "allowed", "denied",
            "tier_changed", "delivered", "delivery_refused", "captured", "pushed", "lockdown", "doctor_failed"
        ])
    }

    @Test func externalStringsAreCleanedAndMarkedUntrusted() throws {
        var chain = AuditChain()
        let opened = try AuditChain.encodeLine(try chain.append(.chainOpened(day: "2026-09-19"), at: date))
        let hostile = "claude\n{\"kind\":\"revoked\"}\u{1B}[31m\u{202E}x"
        let record = try chain.append(.delivered(target: hostile, device: "ipad\u{0}", text: "ls", confirmed: false,
                                                 guardHits: ["rm -rf\r"], stripped: 0), at: date)
        #expect(record.untrusted == ["device", "guard_hits", "target"])
        #expect(record.fields["target"] == .string("claude\\u{A}{\"kind\":\"revoked\"}\\u{1B}[31m\\u{202E}x"))
        #expect(record.fields["device"] == .string("ipad\\u{0}"))
        #expect(record.fields["guard_hits"] == .strings(["rm -rf\\u{D}"]))
        let line = try AuditChain.encodeLine(record)
        #expect(!line.contains("\n") && !line.contains("\u{1B}") && !line.contains("\u{202E}"))
        #expect(try AuditChain.verify(lines: [opened, line]).count == 2)
    }

    @Test func longStringsAreCappedWithTheDroppedCount() {
        let long = String(repeating: "a", count: 1_000)
        let cleaned = AuditField.clean(long)
        #expect(cleaned.hasSuffix("…[+744]"))
        #expect(cleaned.unicodeScalars.count == AuditField.maxScalars + "…[+744]".unicodeScalars.count)
        #expect(AuditField.clean("") == "")
        #expect(AuditField.clean("plain ünïcödé 🔥") == "plain ünïcödé 🔥")
        #expect(AuditField.clean("a\u{200B}b") == "a\\u{200B}b", "format characters are shown, not hidden")
        #expect(AuditField.clean("literal \\u{A} and …[+3]") == "literal \\u{5C}u{A} and \\u{2026}[+3]",
                "a backslash or an ellipsis in the input can never pass for an escape or the marker")
    }

    @Test func guardHitsAreCappedWithTheDroppedCount() throws {
        var chain = AuditChain()
        _ = try chain.append(.chainOpened(day: "2026-09-19"), at: date)
        let hits = (0..<40).map { "rule\($0)" }
        let record = try chain.append(.delivered(target: "tmux:a", device: "ipad", text: "x", confirmed: false,
                                                 guardHits: hits, stripped: 0), at: date)
        guard case .strings(let stored)? = record.fields["guard_hits"] else {
            Issue.record("guard_hits missing")
            return
        }
        #expect(stored.count == AuditChain.maxGuardHits + 1 && stored.last == "…[+8]")
    }

    @Test func numbersAndBooleansRoundTripAsThemselves() throws {
        var chain = AuditChain()
        _ = try chain.append(.chainOpened(day: "2026-09-19"), at: date)
        let pushed = try chain.append(.pushed(tool: "vbsay", target: "tmux:a", bytes: 12), at: date)
        let line = try AuditChain.encodeLine(pushed)
        let record = try JSONDecoder().decode(AuditRecord.self, from: Data(line.utf8))
        #expect(record.fields["bytes"] == .int(12))
        #expect(record.fields["tool"] == .string("vbsay"))
        #expect(record.untrusted == ["target", "tool"])
        #expect(record.at == "2026-09-19T06:40:00.000Z", "UTC, RFC 3339, milliseconds")
    }
}
