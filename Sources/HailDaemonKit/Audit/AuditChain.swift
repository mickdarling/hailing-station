import CryptoKit
public import Foundation

/// Why a chain did not verify; `seq` and `line` (zero-based) name the first record that broke it.
public enum AuditVerifyError: Error, Equatable, Sendable {
    case malformed(line: Int, reason: String)
    case hashMismatch(line: Int, seq: UInt64)
    case brokenLink(line: Int, seq: UInt64)
    case sequenceGap(line: Int, expected: UInt64, found: UInt64)
    case unsupportedVersion(line: Int, found: Int)
    case notOpened
    /// A `chain_opened` record after the first: a second salt mid-chain is never legitimate.
    case reopened(line: Int)
}

/// The pure part of the audit log (#42): builds records in order, hashes each over the canonical
/// encoding of everything but `hash` plus a domain tag, links it to the previous hash, and verifies a
/// sequence of lines. Nothing here touches files; the writer (append-only day files, rotation, the
/// signature at rotation once the host key exists, #39) is the next slice.
public struct AuditChain: Sendable, Equatable {
    public static let genesis = String(repeating: "0", count: 64)
    static let recordTag = "hail/audit/1\n"
    static let textTag = "hail/audit-text/1\n"

    /// Random per chain, recorded in the `chain_opened` record and mixed into `textHash`. It is a nonce,
    /// not a key: it lives in the same file, so it defeats precomputed tables across chains and nothing
    /// more. Keying the text hash with the host key waits for #39 (residual in the threat model).
    public let salt: String
    public private(set) var lastHash: String
    public private(set) var nextSeq: UInt64
    private var opened = false

    /// A new chain with a fresh random salt; the first `append` must be `.chainOpened`.
    public init(salt: String? = nil) {
        self.salt = salt ?? Self.hex(Array(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }))
        lastHash = Self.genesis
        nextSeq = 0
    }

    /// Continues a chain from what `verify` proved about its file (`tail`) and its `chain_opened` record,
    /// which is schema-checked and re-hashed so the salt every later `text_hash` uses is the one the
    /// verified file carries. A caller that has not run `verify` has no `Tail` to pass.
    public init(continuing tail: Tail, first: AuditRecord) throws {
        guard first.version == AuditRecord.version else {
            throw AuditVerifyError.unsupportedVersion(line: 0, found: first.version)
        }
        if let reason = Self.schemaProblem(first) { throw AuditVerifyError.malformed(line: 0, reason: reason) }
        guard try Self.hash(of: first) == first.hash else { throw AuditVerifyError.hashMismatch(line: 0, seq: 0) }
        guard first.seq == 0, first.kind == "chain_opened", case .string(let salt)? = first.fields["salt"],
              tail.count >= 1 else { throw AuditVerifyError.notOpened }
        self.salt = salt
        lastHash = tail.lastHash
        nextSeq = UInt64(tail.count)
        opened = true
    }

    /// Builds, hashes, and links the next record. The first record of a chain is always `chain_opened`
    /// and carries the salt; appending anything else first is refused so no record exists without it.
    public mutating func append(_ event: AuditEvent, at date: Date) throws -> AuditRecord {
        if case .chainOpened = event {
            if opened { throw AuditVerifyError.reopened(line: Int(clamping: nextSeq)) }
        } else if !opened {
            throw AuditVerifyError.notOpened
        }
        var record = AuditRecord(
            seq: nextSeq, at: Self.timestamp(date), kind: event.kind, fields: [:], untrusted: [],
            prev: lastHash, hash: ""
        )
        (record.fields, record.untrusted) = fields(for: event)
        record.hash = try Self.hash(of: record)
        let (next, overflow) = nextSeq.addingReportingOverflow(1)
        guard !overflow else {
            throw AuditVerifyError.sequenceGap(line: Int.max, expected: nextSeq, found: nextSeq)
        }
        lastHash = record.hash
        nextSeq = next
        opened = true
        return record
    }

    /// One JSON object, sorted keys, no newline inside; the writer appends a newline.
    public static func encodeLine(_ record: AuditRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = String(data: try encoder.encode(record), encoding: .utf8) else {
            throw AuditVerifyError.malformed(line: Int(clamping: record.seq), reason: "not UTF-8")
        }
        return line
    }

    /// What `verify` proves: how many lines held, and the hash the next record must link to. A chain
    /// cut short after its first record still verifies as a shorter chain, so the writer compares
    /// `lastHash` with the one it last wrote, and the day file is signed at rotation once the host key
    /// exists (#39).
    public struct Tail: Sendable, Equatable {
        public var count: Int
        public var lastHash: String
    }

    /// Walks the lines: each parses with no unknown keys, is byte-for-byte its own canonical encoding
    /// (a rewrite that only changes whitespace, key order, or escaping is still a rewrite), has this
    /// version, recomputes to its own hash, links to the previous hash, and follows in sequence; the
    /// first must be `chain_opened`, so an emptied file does not verify.
    @discardableResult
    public static func verify(lines: [String]) throws -> Tail {
        guard !lines.isEmpty else { throw AuditVerifyError.notOpened }
        var prev = genesis
        for (index, line) in lines.enumerated() {
            prev = try check(line: line, at: index, prev: prev).hash
        }
        return Tail(count: lines.count, lastHash: prev)
    }

    private static func check(line: String, at index: Int, prev: String) throws -> AuditRecord {
        let record: AuditRecord
        do {
            record = try JSONDecoder().decode(AuditRecord.self, from: Data(line.utf8))
        } catch {
            // The decoder's text can quote the corrupt bytes; clean it like any other external string.
            throw AuditVerifyError.malformed(line: index, reason: AuditField.clean("\(error)"))
        }
        guard record.version == AuditRecord.version else {
            throw AuditVerifyError.unsupportedVersion(line: index, found: record.version)
        }
        guard Data(try encodeLine(record).utf8) == Data(line.utf8) else {
            throw AuditVerifyError.malformed(line: index, reason: "not the canonical encoding")
        }
        if let reason = schemaProblem(record) { throw AuditVerifyError.malformed(line: index, reason: reason) }
        let opens = record.kind == "chain_opened"
        if index == 0, !opens { throw AuditVerifyError.notOpened }
        if index > 0, opens { throw AuditVerifyError.reopened(line: index) }
        guard record.seq == UInt64(index) else {
            throw AuditVerifyError.sequenceGap(line: index, expected: UInt64(index), found: record.seq)
        }
        guard record.prev == prev else { throw AuditVerifyError.brokenLink(line: index, seq: record.seq) }
        guard try hash(of: record) == record.hash else {
            throw AuditVerifyError.hashMismatch(line: index, seq: record.seq)
        }
        return record
    }

    /// SHA-256 over the domain tag and the canonical encoding (sorted keys, Foundation's escaping, pinned
    /// by the golden fixture under `fixtures/audit/`) of the record with `hash` blanked.
    static func hash(of record: AuditRecord) throws -> String {
        var unsealed = record
        unsealed.hash = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return hex(Array(SHA256.hash(data: Array(recordTag.utf8) + (try encoder.encode(unsealed)))))
    }

    /// The salted digest stored in place of delivered text; salt and text are length-prefixed.
    public func textHash(_ text: String) -> String {
        var bytes = Array(Self.textTag.utf8)
        for part in [salt, text] {
            let utf8 = Array(part.utf8)
            bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(utf8.count) >> ($0 * 8)) } + utf8
        }
        return Self.hex(Array(SHA256.hash(data: bytes)))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return byte < 16 ? "0" + digits : digits
        }.joined()
    }
}
