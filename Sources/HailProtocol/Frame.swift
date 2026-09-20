public import Foundation

/// One message between a terminal and a host daemon (#2). The envelope is stable; payloads vary by `type`.
/// Unknown types decode to `.unknown` so an older end can ignore what a newer end sends.
public struct Frame: Codable, Sendable, Equatable {
    /// Protocol version the sender speaks.
    public var version: Int
    public var id: UUID
    /// Sender clock, milliseconds since the Unix epoch.
    public var timestamp: Int64
    /// Target id (for example `tmux:claude-hail`); absent on control frames that address the host itself.
    public var target: String?
    /// `terminal`, or the target id that produced the output.
    public var source: String
    public var payload: FramePayload

    public init(
        version: Int = ProtocolVersion.current,
        id: UUID = UUID(),
        timestamp: Int64,
        target: String? = nil,
        source: String,
        payload: FramePayload
    ) {
        self.version = version
        self.id = id
        self.timestamp = timestamp
        self.target = target
        self.source = source
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v", id, timestamp = "ts", type, target, source, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        source = try container.decode(String.self, forKey: .source)
        let rawType = try container.decode(String.self, forKey: .type)
        // Envelope limits the schema also states (#2, #62 review): v >= 1, ts >= 0, non-empty source and target.
        guard version >= 1, timestamp >= 0, !source.isEmpty, target?.isEmpty != true else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "envelope out of range"
            )
            throw DecodingError.dataCorrupted(context)
        }
        payload = try FramePayload(rawType: rawType, container: container, key: .payload)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encode(source, forKey: .source)
        try container.encode(payload.rawType, forKey: .type)
        try payload.encodePayload(into: &container, key: .payload)
    }
}

/// The typed payload of a frame.
public enum FramePayload: Sendable, Equatable {
    case text(TextPayload)
    case audio(AudioPayload)
    case image(ImagePayload)
    case frame(ScreenFramePayload)
    case control(ControlPayload)
    /// A type this build does not understand. Renderers show a placeholder (#7); forwarders re-emit
    /// the original payload untouched so a newer terminal still receives it.
    case unknown(type: String, payload: JSONValue)

    public var type: FrameType? {
        FrameType(rawValue: rawType)
    }

    var rawType: String {
        switch self {
        case .text: FrameType.text.rawValue
        case .audio: FrameType.audio.rawValue
        case .image: FrameType.image.rawValue
        case .frame: FrameType.frame.rawValue
        case .control: FrameType.control.rawValue
        case .unknown(let type, _): type
        }
    }

    init<K: CodingKey>(rawType: String, container: KeyedDecodingContainer<K>, key: K) throws {
        switch FrameType(rawValue: rawType) {
        case .text: self = .text(try container.decode(TextPayload.self, forKey: key))
        case .audio: self = .audio(try container.decode(AudioPayload.self, forKey: key))
        case .image: self = .image(try container.decode(ImagePayload.self, forKey: key))
        case .frame: self = .frame(try container.decode(ScreenFramePayload.self, forKey: key))
        case .control: self = .control(try container.decode(ControlPayload.self, forKey: key))
        case .none: self = .unknown(type: rawType, payload: try container.decode(JSONValue.self, forKey: key))
        }
    }

    func encodePayload<K: CodingKey>(into container: inout KeyedEncodingContainer<K>, key: K) throws {
        switch self {
        case .text(let payload): try container.encode(payload, forKey: key)
        case .audio(let payload): try container.encode(payload, forKey: key)
        case .image(let payload): try container.encode(payload, forKey: key)
        case .frame(let payload): try container.encode(payload, forKey: key)
        case .control(let payload): try container.encode(payload, forKey: key)
        case .unknown(_, let payload): try container.encode(payload, forKey: key)
        }
    }
}
