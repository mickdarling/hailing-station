public import Foundation

/// The shape checks and the timestamp form for v1 records (#42), kept beside the chain.
extension AuditChain {
    /// The shape a v1 record must have beyond what `Codable` checks: a known kind, `untrusted` naming only
    /// keys that exist, hex hashes, and a timestamp in the form this chain writes.
    /// The keys every record of a kind must carry; extra keys are allowed (a later minor version may add
    /// one), missing ones are not. Pinned by `AuditCoverageTests`.
    static let requiredKeys: [String: Set<String>] = [
        "chain_opened": ["salt", "day"], "paired": ["device"],
        "revoked": ["device"], "rotated": ["key_id"],
        "connected": ["device"], "disconnected": ["device", "reason"], "allowed": ["target", "tier", "capture"],
        "denied": ["target"], "tier_changed": ["target", "tier"],
        "delivered": ["target", "device", "text_hash", "bytes", "confirmed", "guard_hits", "stripped"],
        "delivery_refused": ["target", "device", "reason"], "captured": ["target", "device"],
        "pushed": ["tool", "target", "bytes"], "lockdown": ["on", "reason"], "doctor_failed": ["check", "reason"]
    ]

    static func schemaProblem(_ record: AuditRecord) -> String? {
        guard let required = requiredKeys[record.kind] else { return "unknown kind" }
        guard required.isSubset(of: record.fields.keys) else {
            return "\(record.kind) is missing a required field"
        }
        if record.kind == "chain_opened", let problem = chainOpeningProblem(record) { return problem }
        guard record.untrusted.allSatisfy({ record.fields[$0] != nil }) else { return "untrusted names a missing key" }
        guard record.untrusted == record.untrusted.sorted(), Set(record.untrusted).count == record.untrusted.count
        else { return "untrusted is not sorted and distinct" }
        for hash in [record.prev, record.hash] where hash.count != 64 || !hash.allSatisfy(\.isHexDigit) {
            return "hash is not 64 hex digits"
        }
        guard timestampHasShape(record.at) else { return "timestamp is not YYYY-MM-DDTHH:MM:SS.mmmZ" }
        return nil
    }

    private static func chainOpeningProblem(_ record: AuditRecord) -> String? {
        guard case .string(let salt)? = record.fields["salt"], salt.count == 64, salt.allSatisfy(\.isHexDigit)
        else { return "salt is not 64 hex digits" }
        guard case .string(let day)? = record.fields["day"], dayHasShape(day) else {
            return "day is not YYYY-MM-DD"
        }
        let previousDayField = record.fields["previous_day"]
        let previousHashField = record.fields["previous_hash"]
        if previousDayField == nil, previousHashField == nil { return nil }  // legacy v1, before day links
        guard case .string(let previousDay)? = previousDayField,
              previousDay.isEmpty || dayHasShape(previousDay) else {
            return "previous_day is not empty or YYYY-MM-DD"
        }
        guard case .string(let previousHash)? = previousHashField,
              previousHash.count == 64, previousHash.allSatisfy(\.isHexDigit) else {
            return "previous_hash is not 64 hex digits"
        }
        guard previousDay.isEmpty ? previousHash == genesis : previousDay < day && previousHash != genesis else {
            return "previous day link is inconsistent"
        }
        return nil
    }

    static func dayHasShape(_ day: String) -> Bool { hasShape(day, "0000-00-00") }

    static func timestampHasShape(_ at: String) -> Bool { hasShape(at, "0000-00-00T00:00:00.000Z") }

    private static func hasShape(_ value: String, _ pattern: String) -> Bool {
        let actual = Array(value.unicodeScalars)
        let shape = Array(pattern.unicodeScalars)
        guard actual.count == shape.count else { return false }
        for (scalar, pattern) in zip(actual, shape) {
            if pattern == "0" {
                guard scalar.isASCII, scalar.properties.numericType == .decimal else { return false }
            } else if scalar != pattern {
                return false
            }
        }
        return true
    }

    /// The day a date falls on in UTC, as a day file is named.
    public static func day(of date: Date) -> String { String(timestamp(date).prefix(10)) }

    /// RFC 3339 UTC with milliseconds (rounded), formatted by hand: no formatter object per record.
    static func timestamp(_ date: Date) -> String {
        let epochMillis = Int64((date.timeIntervalSince1970 * 1_000).rounded())
        // Floor division, so a date before 1970 still yields milliseconds in 0...999.
        let seconds = epochMillis >= 0 ? epochMillis / 1_000 : -((-epochMillis + 999) / 1_000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let millis = Int(epochMillis - seconds * 1_000)
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))T\(pad(parts.hour, 2)):"
            + "\(pad(parts.minute, 2)):\(pad(parts.second, 2)).\(pad(millis, 3))Z"
    }
}
