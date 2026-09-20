/// How each `AuditEvent` becomes stored fields (#42 item 2). Every external string is cleaned and named
/// in `untrusted`; numbers and booleans are the daemon's own; delivered text becomes its salted hash.
extension AuditChain {
    /// Longest `guard_hits` list stored; the rest is one `…[+N]` element (rule names come from the policy).
    static let maxGuardHits = 32

    /// The stored fields for an event, every external string cleaned and named in `untrusted`. Numbers
    /// and booleans are the daemon's own; `text` becomes its salted hash and byte length. Both switches
    /// are exhaustive on purpose: a new case must be placed, and the coverage test asserts it stores
    /// something.
    func fields(for event: AuditEvent) -> ([String: AuditValue], [String]) {
        var builder = FieldBuilder()
        switch event {
        case .chainOpened(let day):
            builder.own("salt", .string(salt))
            builder.own("day", .string(AuditField.clean(day)))
            builder.own("previous_day", .string(""))
            builder.own("previous_hash", .string(Self.genesis))
        case .paired(let device), .revoked(let device), .connected(let device):
            builder.device(device)
        case .rotated(let keyID):
            builder.own("key_id", .string(AuditField.clean(keyID)))
        case .disconnected(let device, let reason):
            builder.device(device)
            builder.external("reason", reason)
        case .allowed(let target, let tier, let capture):
            builder.external("target", target)
            builder.own("tier", .string(AuditField.clean(tier)))
            builder.own("capture", .bool(capture))
        case .denied(let target):
            builder.external("target", target)
        case .tierChanged(let target, let tier):
            builder.external("target", target)
            builder.own("tier", .string(AuditField.clean(tier)))
        case .lockdown(let on, let reason):
            builder.own("on", .bool(on))
            builder.external("reason", reason)
        case .doctorFailed(let check, let reason):
            builder.own("check", .string(AuditField.clean(check)))
            builder.external("reason", reason)
        case .delivered, .deliveryRefused, .captured, .pushed:
            deliveryFields(for: event, into: &builder)
        }
        return (builder.fields, builder.untrusted.sorted())
    }

    private func deliveryFields(for event: AuditEvent, into builder: inout FieldBuilder) {
        switch event {
        case .delivered(let target, let device, let text, let confirmed, let guardHits, let stripped):
            builder.external("target", target)
            builder.device(device)
            builder.own("text_hash", .string(textHash(text)))
            builder.own("bytes", .int(text.utf8.count))
            builder.own("confirmed", .bool(confirmed))
            // Rule names come from the unsigned policy file (#41), so they are external too.
            var hits = guardHits.prefix(Self.maxGuardHits).map(AuditField.clean)
            if guardHits.count > Self.maxGuardHits { hits.append("…[+\(guardHits.count - Self.maxGuardHits)]") }
            builder.fields["guard_hits"] = .strings(hits)
            builder.untrusted.append("guard_hits")
            builder.own("stripped", .int(stripped))
        case .deliveryRefused(let target, let device, let reason):
            builder.external("target", target)
            builder.device(device)
            builder.external("reason", reason)
        case .captured(let target, let device):
            builder.external("target", target)
            builder.device(device)
        case .pushed(let tool, let target, let bytes):
            builder.external("tool", tool)
            builder.external("target", target)
            builder.own("bytes", .int(bytes))
        case .chainOpened, .paired, .revoked, .rotated, .connected, .disconnected, .allowed, .denied, .tierChanged,
             .lockdown, .doctorFailed:
            break
        }
    }

    struct FieldBuilder {
        var fields: [String: AuditValue] = [:]
        var untrusted: [String] = []

        mutating func own(_ key: String, _ value: AuditValue) { fields[key] = value }

        mutating func external(_ key: String, _ value: String) {
            fields[key] = .string(AuditField.clean(value))
            untrusted.append(key)
        }

        /// The name is external; the key id, when #39 supplies one, is the daemon's own.
        mutating func device(_ device: AuditDevice) {
            external("device", device.name)
            if let keyID = device.keyID { own("device_key", .string(AuditField.clean(keyID))) }
        }
    }
}
