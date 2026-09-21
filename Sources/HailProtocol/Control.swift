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
}

extension ControlPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, hello, targets, targetID = "target", nonce, code, message
    }

    private enum Command: String, Codable {
        case hello, listTargets = "list_targets", targets, select, subscribe, unsubscribe, escape, ping, pong, error
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
        }
    }

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
