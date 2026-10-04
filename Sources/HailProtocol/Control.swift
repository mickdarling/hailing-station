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

    public init(versions: [Int], capabilities: [String], deviceName: String) {
        self.versions = versions
        self.capabilities = capabilities
        self.deviceName = deviceName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versions = try container.decode([Int].self, forKey: .versions)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        guard !versions.isEmpty else {
            let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "no versions")
            throw DecodingError.dataCorrupted(context)
        }
    }

    private enum CodingKeys: String, CodingKey { case versions, capabilities, deviceName }
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
}

extension ControlPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, hello, targets, targetID = "target", nonce, code, message, events
    }

    private enum Command: String, Codable {
        case hello, listTargets = "list_targets", targets, select, subscribe, unsubscribe, escape, ping, pong, error
        case diagnostic
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
            let events = try container.decode([DiagnosticEvent].self, forKey: .events)
            try requireRange(events.count, in: 1...DiagnosticLimits.maxEventsPerBatch, "events", decoder)
            self = .diagnostic(events: events)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
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
        }
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

/// Bounds on device diagnostics (#234). A batch is small, every value is a scalar, and strings are short
/// tokens with no spaces, so no transcript, reply text or request content fits through this channel.
public enum DiagnosticLimits {
    /// The host capability that admits `diagnostic` frames. A host without it never receives one.
    public static let capability = "device_diagnostics"
    public static let maxEventsPerBatch = 32
    public static let maxTokenLength = 32
    public static let integers: ClosedRange<Int64> = -2_147_483_648...2_147_483_647
    /// Letters, digits and `._:-`: enough for versions, enum names and port types, never a sentence.
    public static let tokenCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")

    public static func isToken(_ value: String) -> Bool {
        (1...maxTokenLength).contains(value.count) && value.allSatisfy(tokenCharacters.contains)
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

/// The closed set of field keys, each with one fixed value kind.
public enum DiagnosticField: String, Codable, Sendable, CaseIterable, Comparable {
    case reason, state, code, domain, route, app, build, os, device
    case error, attempt, count, ms
    case on

    public enum Kind: Sendable { case token, integer, boolean }

    public var kind: Kind {
        switch self {
        case .reason, .state, .code, .domain, .route, .app, .build, .os, .device: .token
        case .error, .attempt, .count, .ms: .integer
        case .on: .boolean
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum DiagnosticValue: Sendable, Equatable {
    case token(String)
    case integer(Int64)
    case boolean(Bool)

    var kind: DiagnosticField.Kind {
        switch self {
        case .token: .token
        case .integer: .integer
        case .boolean: .boolean
        }
    }

    var isWithinLimits: Bool {
        switch self {
        case .token(let value): DiagnosticLimits.isToken(value)
        case .integer(let value): DiagnosticLimits.integers.contains(value)
        case .boolean: true
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
        for (field, value) in fields where value.kind != field.kind || !value.isWithinLimits {
            throw DiagnosticEventInvalid(field: field)
        }
        self.timestamp = timestamp
        self.name = name
        self.fields = fields
    }
}

extension DiagnosticEvent: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// Unknown keys are refused here, unlike the rest of the protocol: free data must not ride along.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: ["ts", "name", "fields"]) else {
            throw Self.corrupt(decoder, "unknown diagnostic event key")
        }
        let timestamp = try container.decode(Int64.self, forKey: Key(stringValue: "ts"))
        let name = try container.decode(DiagnosticEventName.self, forKey: Key(stringValue: "name"))
        var fields: [DiagnosticField: DiagnosticValue] = [:]
        if container.contains(Key(stringValue: "fields")) {
            let values = try container.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "fields"))
            for key in values.allKeys {
                guard let field = DiagnosticField(rawValue: key.stringValue) else {
                    throw Self.corrupt(decoder, "unknown diagnostic field")
                }
                switch field.kind {
                case .token: fields[field] = .token(try values.decode(String.self, forKey: key))
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
                        ($0.rawValue, diagnosticValue($0.kind))
                    }))
                ])
            ])
        ])
    ])

    private static func diagnosticValue(_ kind: DiagnosticField.Kind) -> JSONValue {
        switch kind {
        case .token:
            .object([
                "type": .string("string"), "minLength": .integer(1),
                "maxLength": .integer(Int64(DiagnosticLimits.maxTokenLength)),
                "pattern": .string("^[A-Za-z0-9._:-]+$")
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
