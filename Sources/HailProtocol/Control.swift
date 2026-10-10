// The control command set and the diagnostic event vocabulary (#234) it carries stay together, so every
// bound a peer can send is visible in one file.
// swiftlint:disable file_length

/// A target as the host lists it (#8, #10).
public struct TargetInfo: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var name: String
    public var alive: Bool

    public init(id: String, kind: String, name: String, alive: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.alive = alive
    }
}

/// Bounds on control fields so free text from a peer or a host-side tool stays small (#7, #44).
public enum ControlLimits {
    public static let maxErrorMessage = 256
}

/// What each end says first. `versions` lists every protocol version it can speak and is never empty,
/// so negotiation can fail closed instead of guessing (#2 item 5, threat model B2 downgrade).
public struct HelloInfo: Codable, Sendable, Equatable {
    public var versions: [Int]
    public var capabilities: [String]
    public var deviceName: String
    /// The device's class only (#366): `phone`, `pad` or `mac` from `AmbientTakeOver.deviceKinds`, never its
    /// name. Optional, so an older peer's hello is unchanged; a value outside the vocabulary fails the hello.
    public var deviceKind: String?

    public init(versions: [Int], capabilities: [String], deviceName: String, deviceKind: String? = nil) {
        self.versions = versions
        self.capabilities = capabilities
        self.deviceName = deviceName
        self.deviceKind = AmbientTakeOver.deviceKind(deviceKind)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versions = try container.decode([Int].self, forKey: .versions)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .deviceKind)
        deviceKind = AmbientTakeOver.deviceKind(rawKind)
        // Strict: we control every client, so a kind outside the vocabulary is a bug, not a future value.
        guard rawKind == nil || deviceKind != nil else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath + [CodingKeys.deviceKind], debugDescription: "unknown device kind"
            )
            throw DecodingError.dataCorrupted(context)
        }
        guard !versions.isEmpty else {
            let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "no versions")
            throw DecodingError.dataCorrupted(context)
        }
    }

    private enum CodingKeys: String, CodingKey { case versions, capabilities, deviceName, deviceKind }
}

/// Closed set of error codes. Unknown strings decode to `.unknown` so a newer peer's code is kept, not lost.
public enum ErrorCode: Sendable, Equatable, Codable {
    case unauthorized, unknownTarget, notAllowed, lockdown, rateLimited, protocolVersion, malformed
    case unknown(String)

    private static let names: [String: ErrorCode] = [
        "unauthorized": .unauthorized, "unknown_target": .unknownTarget, "not_allowed": .notAllowed,
        "lockdown": .lockdown, "rate_limited": .rateLimited, "protocol_version": .protocolVersion,
        "malformed": .malformed
    ]

    public var rawValue: String {
        if case .unknown(let raw) = self { return raw }
        return Self.names.first { $0.value == self }?.key ?? "unknown"
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.names[raw] ?? .unknown(raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The control command set. Encoded as `{"command": "...", ...fields}` inside the frame payload.
public enum ControlPayload: Sendable, Equatable {
    case hello(HelloInfo)
    case listTargets
    case targets([TargetInfo])
    case select(targetID: String)
    case subscribe(targetID: String)
    case unsubscribe(targetID: String)
    /// Send one literal Escape key to the selected target. This is intentionally narrower than a
    /// generic remote-key command so the fast cancellation path cannot become arbitrary input.
    case escape(targetID: String)
    case ping(nonce: String)
    case pong(nonce: String)
    case error(code: ErrorCode, message: String)
    /// Device diagnostics (#234): enumerated events with bounded scalar fields, sent only to a host that
    /// advertises `DiagnosticLimits.capability`. They carry no audio or text and grant no authority.
    case diagnostic(events: [DiagnosticEvent])
    /// Host to device (#309): stop reply playback now and drop queued reply audio, sent only to a device that
    /// advertises `PlaybackStop.capability`. It carries nothing else and grants no authority.
    case stopPlayback
    /// Host to device (#366): this connection's new ambient stream took listening over from another device of
    /// kind `from` (an `AmbientTakeOver.deviceKinds` token, or nil when that device did not say). Sent only to a
    /// device that advertises `AmbientTakeOver.capability`. It carries nothing else and grants no authority.
    case ambientMovedHere(from: String?)
    /// Host to device (#318): the request this connection's ambient stream just handed to `targetID`, as heard,
    /// so the device can show the user's own words in the thread. Sent only to the device that spoke, before the
    /// request is typed, and only when it advertises `AmbientHeard.capability`. It grants no authority.
    case ambientHeard(targetID: String, text: String)
}

extension ControlPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, hello, targets, targetID = "target", nonce, code, message, events, from, text
    }

    private enum Command: String, Codable {
        case hello, listTargets = "list_targets", targets, select, subscribe, unsubscribe, escape, ping, pong, error
        case diagnostic, stopPlayback = "stop_playback", ambientMovedHere = "ambient_moved_here"
        case ambientHeard = "ambient_heard"
    }

    // A closed wire enum is clearest as one exhaustive switch.
    // swiftlint:disable:next cyclomatic_complexity
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Command.self, forKey: .command) {
        case .hello: self = .hello(try container.decode(HelloInfo.self, forKey: .hello))
        case .listTargets: self = .listTargets
        case .targets: self = .targets(try container.decode([TargetInfo].self, forKey: .targets))
        case .select: self = .select(targetID: try container.decode(String.self, forKey: .targetID))
        case .subscribe: self = .subscribe(targetID: try container.decode(String.self, forKey: .targetID))
        case .unsubscribe: self = .unsubscribe(targetID: try container.decode(String.self, forKey: .targetID))
        case .escape: self = .escape(targetID: try container.decode(String.self, forKey: .targetID))
        case .ping: self = .ping(nonce: try container.decode(String.self, forKey: .nonce))
        case .pong: self = .pong(nonce: try container.decode(String.self, forKey: .nonce))
        case .error:
            let message = try container.decode(String.self, forKey: .message)
            guard message.count <= ControlLimits.maxErrorMessage else {
                let context = DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "message too long"
                )
                throw DecodingError.dataCorrupted(context)
            }
            self = .error(code: try container.decode(ErrorCode.self, forKey: .code), message: message)
        case .diagnostic:
            // Strict, unlike the other commands (#234): only `command` and `events`, so nothing rides along.
            try Self.requireOnly(["command", "events"], "diagnostic", decoder)
            let events = try container.decode([DiagnosticEvent].self, forKey: .events)
            try requireRange(events.count, in: 1...DiagnosticLimits.maxEventsPerBatch, "events", decoder)
            self = .diagnostic(events: events)
        case .stopPlayback:
            // Strict, like `diagnostic`: only `command`, so nothing rides along on a stop.
            try Self.requireOnly(["command"], "stop_playback", decoder)
            self = .stopPlayback
        case .ambientMovedHere:
            // Strict, like `stop_playback` (#366): only `command` and an optional class from the closed vocabulary.
            try Self.requireOnly(["command", "from"], "ambient_moved_here", decoder)
            let from = try container.decodeIfPresent(String.self, forKey: .from)
            guard from == nil || AmbientTakeOver.deviceKind(from) != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "unknown ambient_moved_here device"))
            }
            self = .ambientMovedHere(from: from)
        case .ambientHeard: self = try Self.ambientHeard(from: decoder)
        }
    }

    /// Strict (#318): only `command`, a non-empty `target`, and non-empty `text` within the text payload's byte cap.
    private static func ambientHeard(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "target", "text"], "ambient_heard", decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        try requireRange(text.utf8.count, in: 1...PayloadLimits.maxTextBytes, "text", decoder)
        let target = try container.decode(String.self, forKey: .targetID)
        try requireRange(target.utf8.count, in: 1...PayloadLimits.maxTextBytes, "target", decoder)
        return .ambientHeard(targetID: target, text: text)
    }

    /// Refuses any payload key outside `allowed`, so nothing rides along on a strict command.
    private static func requireOnly(_ allowed: [String], _ command: String, _ decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: DiagnosticCodingKey.self).allKeys.map(\.stringValue)
        guard keys.allSatisfy({ DiagnosticLimits.isOne(of: allowed, $0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown \(command) payload key"))
        }
    }

    // One exhaustive switch over the closed wire enum, like the decoder.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let info):
            try container.encode(Command.hello, forKey: .command)
            try container.encode(info, forKey: .hello)
        case .listTargets:
            try container.encode(Command.listTargets, forKey: .command)
        case .targets(let list):
            try container.encode(Command.targets, forKey: .command)
            try container.encode(list, forKey: .targets)
        case .select(let id):
            try container.encode(Command.select, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .subscribe(let id):
            try container.encode(Command.subscribe, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .unsubscribe(let id):
            try container.encode(Command.unsubscribe, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .escape(let id):
            try container.encode(Command.escape, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .ping(let nonce):
            try container.encode(Command.ping, forKey: .command)
            try container.encode(nonce, forKey: .nonce)
        case .pong(let nonce):
            try container.encode(Command.pong, forKey: .command)
            try container.encode(nonce, forKey: .nonce)
        case .error(let code, let message):
            try container.encode(Command.error, forKey: .command)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case .diagnostic(let events):
            try container.encode(Command.diagnostic, forKey: .command)
            try container.encode(events, forKey: .events)
        case .stopPlayback: try container.encode(Command.stopPlayback, forKey: .command)
        case .ambientMovedHere(let from):
            try container.encode(Command.ambientMovedHere, forKey: .command)
            try container.encodeIfPresent(AmbientTakeOver.deviceKind(from), forKey: .from)
        case .ambientHeard(let id, let text):
            try container.encode(Command.ambientHeard, forKey: .command)
            try container.encode(id, forKey: .targetID)
            try container.encode(text, forKey: .text)
        }
    }
}

/// Reply playback stop (#309). The device advertises the capability in its `hello`; a host never sends
/// `stop_playback` to a device without it, because an older device refuses an unknown command as malformed.
public enum PlaybackStop {
    public static let capability = "stop_playback"
}

/// The user's own ambient request, shown in the thread (#318). The device advertises the capability in its `hello`;
/// a host never sends `ambient_heard` to a device without it, because an older device refuses an unknown command.
public enum AmbientHeard {
    public static let capability = "ambient_heard"
}

/// Ambient take-over (#366): the most recent device to start ambient listening on a host takes it over. The
/// host ends the previous device's stream and answers that device's next segment with a `not_allowed` error
/// whose message starts with `movedPrefix`; the new device, if it advertises `capability`, is sent
/// `ambient_moved_here`. A device is named only by its class, from `deviceKinds`.
public enum AmbientTakeOver {
    public static let capability = "ambient_takeover"
    public static let deviceKinds = ["phone", "pad", "mac"]
    public static let movedPrefix = "ambient moved"

    /// `value` when it is exactly one of `deviceKinds`, else nil.
    public static func deviceKind(_ value: String?) -> String? {
        value.flatMap { value in deviceKinds.first { DiagnosticLimits.sameBytes($0, value) } }
    }

    /// The previous device's error message: `ambient moved to pad`, or `ambient moved to another device` when the
    /// new device did not say its class.
    public static func movedMessage(to kind: String?) -> String {
        "\(movedPrefix) to \(deviceKind(kind) ?? "another device")"
    }

    /// Whether an error `message` is a take-over notice and, if it is, the new device's class (nil if unsaid).
    public static func moved(_ message: String) -> (moved: Bool, to: String?) {
        let lead = movedPrefix + " to "
        guard message.hasPrefix(lead) else { return (false, nil) }
        return (true, deviceKind(String(message.dropFirst(lead.count))))
    }
}

/// Picks the protocol version a session runs at: the highest version both ends list (#2 item 5).
public enum VersionNegotiation {
    /// Every version this build can speak, newest first. Grows when `ProtocolVersion.current` bumps (#33).
    public static let supported: [Int] = [ProtocolVersion.current]

    /// Returns `nil` when the sets are disjoint or `offered` is empty. Callers must then send
    /// `.error(code: .protocolVersion, ...)` and close; never fall back to `ProtocolVersion.current`.
    public static func choose(offered: [Int], supported: [Int] = supported) -> Int? {
        Set(offered).intersection(supported).max()
    }
}

/// Bounds on device diagnostics (#234). A batch is small and every value is a scalar: an integer, a boolean,
/// a version number, or a token from its field's closed vocabulary. The log's readers include AI agents, so
/// nothing a peer chooses freely, not even a short phrase, can reach it through this channel.
public enum DiagnosticLimits {
    /// The host capability that admits `diagnostic` frames. A host without it never receives one.
    public static let capability = "device_diagnostics"
    public static let maxEventsPerBatch = 32
    public static let integers: ClosedRange<Int64> = -2_147_483_648...2_147_483_647
    /// One to four dot-separated groups of one to six digits, as in `0.1.84` or `26.0.1`.
    public static let versionPattern = "^[0-9]{1,6}([.][0-9]{1,6}){0,3}$"

    /// Checked on UTF-8 bytes against ASCII ranges, never on Characters or scalars: a digit followed by
    /// invisible tag characters or combining marks is one Character but is not a version.
    public static func isVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var groups = 0, run = 0
        for byte in bytes {
            if (0x30...0x39).contains(byte) {
                run += 1
                guard run <= 6 else { return false }
            } else if byte == 0x2E, run > 0 {
                groups += 1
                run = 0
            } else {
                return false
            }
        }
        return run > 0 && groups <= 3
    }

    /// Byte-for-byte equality of the UTF-8 forms. Swift's `==` on strings is canonical equivalence, which
    /// is not what a closed ASCII vocabulary means.
    public static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Whether `value`'s bytes equal one of `allowed` exactly.
    static func isOne(of allowed: [String], _ value: String) -> Bool {
        allowed.contains { sameBytes($0, value) }
    }
}

/// The closed set of diagnostic events. An unknown name fails decoding; adding one needs a new capability.
public enum DiagnosticEventName: String, Codable, Sendable, CaseIterable {
    case appInfo = "app_info"
    case connectionState = "connection_state"
    case connectionError = "connection_error"
    case ambientStart = "ambient_start"
    case ambientStop = "ambient_stop"
    case routeChange = "route_change"
    case interruptionBegin = "interruption_begin"
    case interruptionEnd = "interruption_end"
    case appBackground = "app_background"
    case appForeground = "app_foreground"
    case hostRefusal = "host_refusal"
    case captureState = "capture_state"
    case captureError = "capture_error"
    case replyPlaybackStart = "reply_playback_start"
    case replyPlaybackEnd = "reply_playback_end"
    case replyPlaybackError = "reply_playback_error"
    case echoGuard = "echo_guard"
    case eventsDropped = "events_dropped"
}

/// The closed set of field keys, each with one fixed value kind. Token fields accept only their own
/// vocabulary; anything a device can't map exactly is sent as `other`.
public enum DiagnosticField: String, Codable, Sendable, CaseIterable, Comparable {
    case reason, state, code, domain, route, device
    case app, build, os
    case error, attempt, count, ms
    case on

    public enum Kind: Sendable { case token, version, integer, boolean }

    public var kind: Kind {
        switch self {
        case .reason, .state, .code, .domain, .route, .device: .token
        case .app, .build, .os: .version
        case .error, .attempt, .count, .ms: .integer
        case .on: .boolean
        }
    }

    /// The vocabulary of a token field, empty for every other kind.
    public var tokens: [String] { DiagnosticVocabulary.tokens[self] ?? [] }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Every value a token field may take (#234). Each list ends in `other`.
public enum DiagnosticVocabulary {
    static let tokens: [DiagnosticField: [String]] = [
        .reason: [
            // AVAudioSession route-change reasons
            "unknown", "new_device_available", "old_device_unavailable", "category_change", "override",
            "wake_from_sleep", "no_suitable_route", "route_configuration_change",
            // AVAudioSession interruption reasons
            "default", "app_was_suspended", "built_in_mic_muted", "scene_was_backgrounded", "route_disconnected",
            // why ambient listening stopped
            "user", "permission_denied", "binding_changed", "background", "start_failed", "capture_ended",
            "system_interruption", "host_refused", "send_failed", "other"
        ],
        .state: [
            "disconnected", "connecting", "negotiating", "ready", "reconnecting", "failed",
            "ended_by_system", "tap_to_talk_start", "tap_to_talk_end", "other"
        ],
        .code: [
            // host ErrorCode names
            "unauthorized", "unknown_target", "not_allowed", "lockdown", "rate_limited", "protocol_version",
            "malformed",
            // dropped-event sources
            "host_rate_limit", "app_buffer",
            // reply playback and capture failures
            "playback_failed", "resume_failed", "replay_failed", "format_unplayable", "conflicting_segment",
            "media_services_reset", "other"
        ],
        .domain: ["avfoundation", "coreaudio", "network", "posix", "other"],
        .route: [
            "none", "built_in_mic", "built_in_speaker", "built_in_receiver", "headphones", "headset_mic",
            "line_in", "line_out", "bluetooth_a2dp", "bluetooth_hfp", "bluetooth_le", "airplay", "hdmi",
            "car_audio", "usb_audio", "other"
        ],
        .device: ["phone", "pad", "mac", "other"]
    ]
}

public enum DiagnosticValue: Sendable, Equatable {
    /// A token-field vocabulary entry, or a version-field number.
    case token(String)
    case integer(Int64)
    case boolean(Bool)

    func isValid(for field: DiagnosticField) -> Bool {
        switch (self, field.kind) {
        case (.token(let value), .token): DiagnosticLimits.isOne(of: field.tokens, value)
        case (.token(let value), .version): DiagnosticLimits.isVersion(value)
        case (.integer(let value), .integer): DiagnosticLimits.integers.contains(value)
        case (.boolean, .boolean): true
        default: false
        }
    }
}

public struct DiagnosticEventInvalid: Error, Equatable, Sendable {
    public let field: DiagnosticField?
}

/// One diagnostic event. Only the validating initializer and the strict decoder can produce one, so an
/// event in hand always has a known name, known field keys, the right kind per key and bounded values.
public struct DiagnosticEvent: Sendable, Equatable {
    /// Milliseconds since 1970 on the device's clock.
    public let timestamp: Int64
    public let name: DiagnosticEventName
    public let fields: [DiagnosticField: DiagnosticValue]

    public init(
        _ name: DiagnosticEventName, timestamp: Int64, fields: [DiagnosticField: DiagnosticValue] = [:]
    ) throws {
        guard timestamp >= 0 else { throw DiagnosticEventInvalid(field: nil) }
        for (field, value) in fields where !value.isValid(for: field) {
            throw DiagnosticEventInvalid(field: field)
        }
        self.timestamp = timestamp
        self.name = name
        self.fields = fields
    }
}

extension DiagnosticEvent: Codable {
    typealias Key = DiagnosticCodingKey

    /// Unknown keys are refused here, unlike the rest of the protocol: free data must not ride along.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.allSatisfy({ DiagnosticLimits.isOne(of: ["ts", "name", "fields"], $0.stringValue) })
        else {
            throw Self.corrupt(decoder, "unknown diagnostic event key")
        }
        let timestamp = try container.decode(Int64.self, forKey: Key(stringValue: "ts"))
        let rawName = try container.decode(String.self, forKey: Key(stringValue: "name"))
        guard let name = DiagnosticEventName.allCases.first(where: { DiagnosticLimits.sameBytes($0.rawValue, rawName) })
        else { throw Self.corrupt(decoder, "unknown diagnostic event name") }
        var fields: [DiagnosticField: DiagnosticValue] = [:]
        if container.contains(Key(stringValue: "fields")) {
            let values = try container.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "fields"))
            for key in values.allKeys {
                guard let field = DiagnosticField.allCases.first(where: {
                    DiagnosticLimits.sameBytes($0.rawValue, key.stringValue)
                }) else {
                    throw Self.corrupt(decoder, "unknown diagnostic field")
                }
                switch field.kind {
                case .token, .version: fields[field] = .token(try values.decode(String.self, forKey: key))
                case .integer: fields[field] = .integer(try values.decode(Int64.self, forKey: key))
                case .boolean: fields[field] = .boolean(try values.decode(Bool.self, forKey: key))
                }
            }
        }
        do {
            try self.init(name, timestamp: timestamp, fields: fields)
        } catch {
            throw Self.corrupt(decoder, "diagnostic value out of bounds")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(timestamp, forKey: Key(stringValue: "ts"))
        try container.encode(name, forKey: Key(stringValue: "name"))
        var values = container.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "fields"))
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            let key = Key(stringValue: field.rawValue)
            switch value {
            case .token(let token): try values.encode(token, forKey: key)
            case .integer(let number): try values.encode(number, forKey: key)
            case .boolean(let flag): try values.encode(flag, forKey: key)
            }
        }
    }

    private static func corrupt(_ decoder: any Decoder, _ reason: String) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: reason))
    }
}

extension Schema {
    /// Strict where the rest of the schema is tolerant (#234): unknown event and field keys are refused.
    static let diagnosticEvents: JSONValue = .object([
        "type": .string("array"), "minItems": .integer(1),
        "maxItems": .integer(Int64(DiagnosticLimits.maxEventsPerBatch)),
        "items": .object([
            "type": .string("object"), "required": .array([.string("ts"), .string("name")]),
            "additionalProperties": .bool(false),
            "properties": .object([
                "ts": .object(["type": .string("integer"), "minimum": .integer(0)]),
                "name": .object(["enum": .array(DiagnosticEventName.allCases.map { .string($0.rawValue) })]),
                "fields": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object(Dictionary(uniqueKeysWithValues: DiagnosticField.allCases.map {
                        ($0.rawValue, diagnosticValue($0))
                    }))
                ])
            ])
        ])
    ])

    /// A `diagnostic` payload carries `command` and `events` and nothing else.
    static let diagnosticPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("diagnostic")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object(["command": .object([:]), "events": .object([:])])
        ])
    ])

    /// `ambient_moved_here` carries `command` and, optionally, a device-class `from` (#366).
    static let ambientMovedHerePayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("ambient_moved_here")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object(["command": .object([:]), "from": .object([:])])
        ])
    ])

    /// `ambient_heard` carries `command`, `target` and `text` and nothing else (#318). The `text` limits live here, not
    /// in the shared control properties, so no other command's extension field named `text` is constrained.
    static let ambientHeardPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("ambient_heard")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]), "target": .object([:]),
                "text": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(PayloadLimits.maxTextBytes))
                ])
            ])
        ])
    ])

    /// `stop_playback` carries only `command` (#309).
    static let stopPlaybackPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("stop_playback")])])]),
        "then": .object(["additionalProperties": .bool(false), "properties": .object(["command": .object([:])])])
    ])

    private static func diagnosticValue(_ field: DiagnosticField) -> JSONValue {
        switch field.kind {
        case .token:
            .object(["enum": .array(field.tokens.map(JSONValue.string))])
        case .version:
            .object([
                "type": .string("string"), "minLength": .integer(1), "maxLength": .integer(27),
                "pattern": .string(DiagnosticLimits.versionPattern)
            ])
        case .integer:
            .object([
                "type": .string("integer"), "minimum": .integer(DiagnosticLimits.integers.lowerBound),
                "maximum": .integer(DiagnosticLimits.integers.upperBound)
            ])
        case .boolean: .object(["type": .string("boolean")])
        }
    }
}

/// Any string key, so the diagnostic decoders can see and refuse keys they don't know.
struct DiagnosticCodingKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}
