import CryptoKit
import Foundation
import Testing
@testable import HailDaemonKit

/// The chain's tamper evidence (#42 acceptance: editing one byte of a past record makes verify fail and
/// name the record).
@Suite struct HashChainTests {
    let date = Date(timeIntervalSince1970: 1_789_800_000.123)

    func chain(_ events: [AuditEvent]) throws -> (AuditChain, [String]) {
        var chain = AuditChain(salt: String(repeating: "ab", count: 32))
        var lines = [try AuditChain.encodeLine(try chain.append(.chainOpened(day: "2026-09-19"), at: date))]
        for event in events { lines.append(try AuditChain.encodeLine(try chain.append(event, at: date))) }
        return (chain, lines)
    }

    var sample: [AuditEvent] {
        [
            .allowed(target: "tmux:claude-hail", tier: "open", capture: false),
            .delivered(target: "tmux:claude-hail", device: "ipad", text: "echo hi", confirmed: false,
                       guardHits: [], stripped: 0),
            .denied(target: "tmux:claude-hail")
        ]
    }

    @Test func recordsLinkInOrderAndVerify() throws {
        let (chain, lines) = try chain(sample)
        #expect(try AuditChain.verify(lines: lines).count == 4)
        let records = try lines.map { try JSONDecoder().decode(AuditRecord.self, from: Data($0.utf8)) }
        #expect(records.map(\.seq) == [0, 1, 2, 3])
        #expect(records[0].prev == AuditChain.genesis)
        #expect(records[1].prev == records[0].hash)
        #expect(records[3].hash == chain.lastHash)
        #expect(records.allSatisfy { $0.hash.count == 64 && $0.hash.allSatisfy(\.isHexDigit) })
        #expect(lines.allSatisfy { !$0.contains("\n") })
    }

    @Test func oneChangedByteInAPastRecordIsNamed() throws {
        let (_, lines) = try chain(sample)
        var edited = lines
        edited[1] = edited[1].replacingOccurrences(of: "\"tier\":\"open\"", with: "\"tier\":\"opeN\"")
        #expect(edited[1] != lines[1])
        #expect(throws: AuditVerifyError.hashMismatch(line: 1, seq: 1)) { try AuditChain.verify(lines: edited) }
    }

    @Test func aRemovedReorderedOrForgedRecordBreaksTheLink() throws {
        let (_, lines) = try chain(sample)
        var removed = lines
        removed.remove(at: 2)
        #expect(throws: AuditVerifyError.sequenceGap(line: 2, expected: 2, found: 3)) {
            try AuditChain.verify(lines: removed)
        }
        var swapped = lines
        swapped.swapAt(1, 2)
        #expect(throws: AuditVerifyError.sequenceGap(line: 1, expected: 1, found: 2)) {
            try AuditChain.verify(lines: swapped)
        }
        // A forged record with a consistent hash of its own but the wrong link.
        var forger = AuditChain(salt: "00")
        _ = try forger.append(.chainOpened(day: "2026-09-19"), at: date)
        var forged = lines
        forged[1] = try AuditChain.encodeLine(try forger.append(.denied(target: "tmux:x"), at: date))
        #expect(throws: AuditVerifyError.brokenLink(line: 1, seq: 1)) { try AuditChain.verify(lines: forged) }
        // Re-sequenced to fit, still the wrong prev.
        #expect(throws: AuditVerifyError.malformed(line: 0, reason: "")) {
            do { try AuditChain.verify(lines: ["not json"]) } catch AuditVerifyError.malformed(let line, _) {
                throw AuditVerifyError.malformed(line: line, reason: "")
            }
        }
    }

    @Test func truncationIsVisibleToACallerThatKnowsTheTail() throws {
        let (chain, lines) = try chain(sample)
        let truncated = Array(lines.dropLast())
        #expect(try AuditChain.verify(lines: truncated).count == 3, "a clean prefix verifies on its own")
        let last = try JSONDecoder().decode(AuditRecord.self, from: Data(truncated[2].utf8))
        #expect(last.hash != chain.lastHash, "the writer compares the file's tail with the hash it last wrote")
        #expect(try AuditChain.verify(lines: truncated).lastHash == last.hash)
        #expect(throws: AuditVerifyError.notOpened) { try AuditChain.verify(lines: []) }
    }

    @Test func aRewriteThatKeepsTheValuesIsStillARewrite() throws {
        let (_, lines) = try chain(sample)
        let line = lines[1]
        let variants = [
            line.replacingOccurrences(of: ",\"kind\"", with: ", \"kind\""),
            "{\"version\":1," + String(line.dropFirst()).replacingOccurrences(of: ",\"version\":1", with: ""),
            line.replacingOccurrences(of: "tmux:claude-hail", with: "tmux:claude\\u002dhail")
        ]
        for variant in variants {
            #expect(variant != line)
            var edited = lines
            edited[1] = variant
            #expect(throws: AuditVerifyError.malformed(line: 1, reason: "not the canonical encoding")) {
                try AuditChain.verify(lines: edited)
            }
        }
    }

    @Test func aTamperedFirstRecordCannotBeContinued() throws {
        let (_, lines) = try chain(sample)
        let tail = try AuditChain.verify(lines: lines)
        var first = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        first.fields["day"] = .string("2026-09-20")
        #expect(throws: AuditVerifyError.hashMismatch(line: 0, seq: 0)) {
            try AuditChain(continuing: tail, first: first)
        }
        let denied = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[3].utf8))
        #expect(throws: AuditVerifyError.notOpened) { try AuditChain(continuing: tail, first: denied) }
    }

    @Test func aPlantedKeyInAPastLineDoesNotVerify() throws {
        let (_, lines) = try chain(sample)
        var planted = lines
        planted[2] = planted[2].replacingOccurrences(of: "{\"at\"", with: "{\"note\":\"benign\",\"at\"")
        #expect(planted[2] != lines[2])
        var caught: AuditVerifyError?
        do { try AuditChain.verify(lines: planted) } catch let error as AuditVerifyError { caught = error }
        guard case .malformed(let line, let reason)? = caught else {
            Issue.record("expected malformed, got \(String(describing: caught))")
            return
        }
        #expect(line == 2 && reason.contains("unknownKeys"))
    }

    @Test func aChainMustOpenFirstAndOnlyOnce() throws {
        var chain = AuditChain()
        #expect(throws: AuditVerifyError.notOpened) { try chain.append(.denied(target: "x"), at: date) }
        let opened = try chain.append(.chainOpened(day: "2026-09-19"), at: date)
        #expect(opened.fields["salt"] == .string(chain.salt))
        #expect(opened.fields["day"] == .string("2026-09-19"))
        #expect(opened.fields["previous_day"] == .string(""))
        #expect(opened.fields["previous_hash"] == .string(AuditChain.genesis))
        #expect(chain.salt.count == 64)
        #expect(throws: AuditVerifyError.reopened(line: 1)) {
            try chain.append(.chainOpened(day: "2026-09-19"), at: date)
        }
        // A hand-built second open that links and hashes correctly is still refused by verify.
        var reopen = AuditRecord(seq: 1, at: "2026-09-19T00:00:00.000Z", kind: "chain_opened",
                                 fields: ["salt": .string(chain.salt), "day": .string("2026-09-19"),
                                          "previous_day": .string(""), "previous_hash": .string(AuditChain.genesis)],
                                 untrusted: [],
                                 prev: opened.hash, hash: "")
        reopen.hash = try AuditChain.hash(of: reopen)
        let lines = [try AuditChain.encodeLine(opened), try AuditChain.encodeLine(reopen)]
        #expect(throws: AuditVerifyError.reopened(line: 1)) { try AuditChain.verify(lines: lines) }
    }
}

@Suite struct AuditGoldenTests {
    /// The canonical bytes are Foundation's sorted-key encoding; this pins them so a library change in
    /// escaping or number formatting is caught here rather than by every past day file failing to verify.
    @Test func goldenLinesMatchByteForByte() throws {
        let (_, lines) = try HashChainTests().chain(HashChainTests().sample + [
            .delivered(target: "tmux:a/b", device: "ipad \"quoted\" \u{1B}[0m", text: "sudo rm -rf /", confirmed: true,
                       guardHits: ["rm -rf", "sudo"], stripped: 3),
            .lockdown(on: true, reason: "five failed handshakes")
        ])
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/audit/chain-v1.jsonl")
        let stored = try String(contentsOf: golden, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(stored == lines)
        #expect(try AuditChain.verify(lines: stored).count == 6)
    }
}
