public import Foundation

/// Text from the terminal to a target, or from a target back. Only `isFinal` text is delivered (#2, #5).
public struct TextPayload: Codable, Sendable, Equatable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool = true) {
        self.text = text
        self.isFinal = isFinal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)
        try requireAtMost(text.utf8.count, PayloadLimits.maxTextBytes, "text", decoder)
    }

    private enum CodingKeys: String, CodingKey { case text, isFinal = "final" }
}

/// Bounds every decoder enforces so consumers never see nonsense dimensions or rates (#2 slice 1b, #44).
public enum PayloadLimits {
    public static let sampleRates = 8_000...96_000
    public static let channels = 1...2
    public static let dimensions = 1...16_384
    /// Raw payload caps per type, from #44: text 8 KB of UTF-8, one audio segment 64 KB, an image 8 MB.
    public static let maxTextBytes = 8 * 1024
    public static let maxAudioBytes = 64 * 1024
    public static let maxImageBytes = 8 * 1024 * 1024
    /// Whole-frame size the shared decoder accepts by default: the largest base64-inflated audio frame plus
    /// envelope headroom. Callers opt in to more only where an image is expected (#7, #44).
    public static let defaultMaxFrameBytes = maxAudioBytes * 4 / 3 + 4 * 1024
}

func requireAtMost(_ count: Int, _ limit: Int, _ name: String, _ decoder: any Decoder) throws {
    guard count <= limit else {
        let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "\(name) too large")
        throw DecodingError.dataCorrupted(context)
    }
}

func requireRange<T: Comparable>(
    _ value: T, in range: ClosedRange<T>, _ name: String, _ decoder: any Decoder
) throws {
    guard range.contains(value) else {
        let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "\(name) out of range")
        throw DecodingError.dataCorrupted(context)
    }
}

func requireNonEmpty(_ value: String, _ name: String, _ decoder: any Decoder) throws {
    guard !value.isEmpty else {
        let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "\(name) is empty")
        throw DecodingError.dataCorrupted(context)
    }
}

/// Codecs an audio segment may use. Segments stay under about two seconds so playback can start early (#2, #7).
public enum AudioCodec: String, Codable, Sendable {
    case opus
    case pcm16
}

/// One short audio segment. `bytes` is base64 in JSON; a binary sidecar is a later decision inside #2.
public struct AudioPayload: Codable, Sendable, Equatable {
    public var codec: AudioCodec
    public var sampleRate: Int
    public var channels: Int
    /// Per-reply sequence number so segments can be reordered and gaps detected.
    public var sequence: Int
    public var bytes: Data

    public init(codec: AudioCodec, sampleRate: Int, channels: Int, sequence: Int, bytes: Data) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.sequence = sequence
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decode(AudioCodec.self, forKey: .codec)
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        channels = try container.decode(Int.self, forKey: .channels)
        sequence = try container.decode(Int.self, forKey: .sequence)
        bytes = try container.decode(Data.self, forKey: .bytes)
        try requireRange(sampleRate, in: PayloadLimits.sampleRates, "sampleRate", decoder)
        try requireRange(channels, in: PayloadLimits.channels, "channels", decoder)
        try requireRange(sequence, in: 0...Int.max, "sequence", decoder)
        try requireAtMost(bytes.count, PayloadLimits.maxAudioBytes, "bytes", decoder)
    }

    private enum CodingKeys: String, CodingKey { case codec, sampleRate, channels, sequence, bytes }
}

/// A still image from a host. Reserved in v1; terminals show a placeholder until #16.
public struct ImagePayload: Codable, Sendable, Equatable {
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var bytes: Data

    public init(mimeType: String, width: Int, height: Int, bytes: Data) {
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        bytes = try container.decode(Data.self, forKey: .bytes)
        try requireNonEmpty(mimeType, "mimeType", decoder)
        try requireRange(width, in: PayloadLimits.dimensions, "width", decoder)
        try requireRange(height, in: PayloadLimits.dimensions, "height", decoder)
        try requireAtMost(bytes.count, PayloadLimits.maxImageBytes, "bytes", decoder)
    }

    private enum CodingKeys: String, CodingKey { case mimeType, width, height, bytes }
}

/// One frame of a low-rate screen stream. Reserved in v1 (#16).
public struct ScreenFramePayload: Codable, Sendable, Equatable {
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var streamID: String
    public var index: Int
    public var bytes: Data

    public init(mimeType: String, width: Int, height: Int, streamID: String, index: Int, bytes: Data) {
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.streamID = streamID
        self.index = index
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        streamID = try container.decode(String.self, forKey: .streamID)
        index = try container.decode(Int.self, forKey: .index)
        bytes = try container.decode(Data.self, forKey: .bytes)
        try requireNonEmpty(mimeType, "mimeType", decoder)
        try requireNonEmpty(streamID, "streamId", decoder)
        try requireRange(width, in: PayloadLimits.dimensions, "width", decoder)
        try requireRange(height, in: PayloadLimits.dimensions, "height", decoder)
        try requireRange(index, in: 0...Int.max, "index", decoder)
        try requireAtMost(bytes.count, PayloadLimits.maxImageBytes, "bytes", decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case mimeType, width, height, streamID = "streamId", index, bytes
    }
}
