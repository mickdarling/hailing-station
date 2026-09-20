import CryptoKit
import Foundation
import Testing
@testable import HailDaemonKit

/// Continuing a chain, the record shape `verify` insists on, the salted text hash, and the version (#42).
@Suite struct AuditVerifyShapeTests {
    let date = Date(timeIntervalSince1970: 1_789_800_000.123)

    @Test func continuingAChainTakesItsSaltFromTheOpenRecord() throws {
        let (chain, lines) = try HashChainTests().chain(HashChainTests().sample)
        let tail = try AuditChain.verify(lines: lines)
        let first = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        var continued = try AuditChain(continuing: tail, first: first)
        let next = try continued.append(.captured(target: "tmux:claude-hail", device: "ipad"), at: date)
        #expect(next.seq == 4 && next.prev == tail.lastHash)
        #expect(try AuditChain.verify(lines: lines + [try AuditChain.encodeLine(next)]).count == 5)
        #expect(continued.textHash("echo hi") == chain.textHash("echo hi"), "the salt came from chain_opened")
        var wrongVersion = first
        wrongVersion.version = 2
        wrongVersion.hash = try AuditChain.hash(of: wrongVersion)
        #expect(throws: AuditVerifyError.unsupportedVersion(line: 0, found: 2)) {
            try AuditChain(continuing: tail, first: wrongVersion)
        }
        var shortSalt = first
        shortSalt.fields["salt"] = .string("ff")
        shortSalt.hash = try AuditChain.hash(of: shortSalt)
        #expect(throws: AuditVerifyError.malformed(line: 0, reason: "salt is not 64 hex digits")) {
            try AuditChain(continuing: tail, first: shortSalt)
        }
    }

    @Test func preEpochTimestampsStayWellFormed() {
        #expect(AuditChain.timestamp(Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500Z")
        #expect(AuditChain.timestamp(Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59.000Z")
        #expect(AuditChain.timestamp(Date(timeIntervalSince1970: -0.0004)) == "1970-01-01T00:00:00.000Z")
        #expect(AuditChain.timestampHasShape(AuditChain.timestamp(Date(timeIntervalSince1970: -86_400.25))))
        #expect(AuditChain.day(of: Date(timeIntervalSince1970: 1_789_800_000)) == "2026-09-19")
    }

    @Test func aDayLinkMustBeAbsentOrPointStrictlyBackward() throws {
        let (_, lines) = try HashChainTests().chain([])
        let original = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        func verify(_ day: String, _ hash: String, reason: String) throws {
            var record = original
            record.fields["previous_day"] = .string(day)
            record.fields["previous_hash"] = .string(hash)
            record.hash = try AuditChain.hash(of: record)
            #expect(throws: AuditVerifyError.malformed(line: 0, reason: reason)) {
                try AuditChain.verify(lines: [try AuditChain.encodeLine(record)])
            }
        }
        try verify("yesterday", AuditChain.genesis, reason: "previous_day is not empty or YYYY-MM-DD")
        try verify("", String(repeating: "a", count: 64), reason: "previous day link is inconsistent")
        try verify("2026-09-19", String(repeating: "a", count: 64), reason: "previous day link is inconsistent")
        try verify("2026-09-18", "short", reason: "previous_hash is not 64 hex digits")
        var incomplete = original
        incomplete.fields.removeValue(forKey: "previous_hash")
        incomplete.hash = try AuditChain.hash(of: incomplete)
        #expect(throws: AuditVerifyError.malformed(line: 0, reason: "previous_hash is not 64 hex digits")) {
            try AuditChain.verify(lines: [try AuditChain.encodeLine(incomplete)])
        }
    }

    @Test func verifyChecksTheShapeNotOnlyTheHashes() throws {
        let (_, lines) = try HashChainTests().chain(HashChainTests().sample)
        let first = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[0].utf8))
        func line(_ mutate: (inout AuditRecord) -> Void) throws -> String {
            var record = AuditRecord(seq: 1, at: "2026-09-19T00:00:00.000Z", kind: "denied",
                                     fields: ["target": .string("x")],
                                          untrusted: ["target"], prev: first.hash, hash: "")
            mutate(&record)
            record.hash = try AuditChain.hash(of: record)
            return try AuditChain.encodeLine(record)
        }
        let cases: [(String, (inout AuditRecord) -> Void)] = [
            ("unknown kind", { $0.kind = "revoked_all" }),
            ("delivered is missing a required field", { $0.kind = "delivered" }),
            ("untrusted names a missing key", { $0.untrusted = ["device"] }),
            ("untrusted is not sorted and distinct", { $0.untrusted = ["target", "target"] }),
            ("timestamp is not YYYY-MM-DDTHH:MM:SS.mmmZ", { $0.at = "2026-09-19 00:00:00" }),
            ("timestamp is not YYYY-MM-DDTHH:MM:SS.mmmZ", { $0.at = "2026-09-19T00:00:00.000+00:00" }),
            ("hash is not 64 hex digits", { $0.prev = String(repeating: "g", count: 64) })
        ]
        for (reason, mutate) in cases {
            #expect(throws: AuditVerifyError.malformed(line: 1, reason: reason)) {
                try AuditChain.verify(lines: [lines[0], try line(mutate)])
            }
        }
        #expect(try AuditChain.verify(lines: [lines[0], try line { _ in }]).count == 2)
    }

    @Test func textIsStoredAsASaltedHashNotAsText() throws {
        let (chain, lines) = try HashChainTests().chain(HashChainTests().sample)
        #expect(!lines[2].contains("echo hi"))
        let record = try JSONDecoder().decode(AuditRecord.self, from: Data(lines[2].utf8))
        #expect(record.fields["text_hash"] == .string(chain.textHash("echo hi")))
        #expect(record.fields["bytes"] == .int(7))
        #expect(AuditChain(salt: "ff").textHash("echo hi") != chain.textHash("echo hi"), "keyed per chain")
        let bare = AuditChain.hex(Array(SHA256.hash(data: Array("echo hi".utf8))))
        #expect(chain.textHash("echo hi") != bare, "not a bare digest")
    }

    @Test func versionIsCheckedBeforeAnythingElse() throws {
        let (_, lines) = try HashChainTests().chain([])
        let bumped = lines[0].replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        #expect(bumped != lines[0])
        #expect(throws: AuditVerifyError.unsupportedVersion(line: 0, found: 2)) {
            try AuditChain.verify(lines: [bumped])
        }
    }
}
