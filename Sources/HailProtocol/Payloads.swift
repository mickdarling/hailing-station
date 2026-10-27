public import Foundation
// Payload definitions intentionally stay together so their shared validation limits remain visible.
// swiftlint:disable file_length

/// Stable identity and arbitration intent shared by every media frame that belongs to one host reply (#14).
/// A nil descriptor means a legacy v1 payload. Consumers may render it, but must not associate it with other
/// legacy frames merely because they arrived next to one another.
public struct ReplyDescriptor: Codable, Sendable, Equatable {
    public var id: UUID
    public var hostID: String
    public var targetID: String
    /// Opaque host-minted input request reference (#161). This field alone grants no recipient authority.
    /// Nil is an uncorrelated legacy/manual reply, not permission to broadcast a personal response.
    public var requestID: UUID?
    /// Present when this reply has audio. The text and every audio segment name the same stream.
    public var audioStreamID: UUID?
    public var priority: ReplyPriority
    public var interruption: ReplyInterruption

    public init(
        id: UUID, hostID: String, targetID: String, audioStreamID: UUID? = nil,
        priority: ReplyPriority = .normal, interruption: ReplyInterruption = .enqueue, requestID: UUID? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.targetID = targetID
        self.requestID = requestID
        self.audioStreamID = audioStreamID
        self.priority = priority
        self.interruption = interruption
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        hostID = try container.decode(String.self, forKey: .hostID)
        targetID = try container.decode(String.self, forKey: .targetID)
        requestID = container.contains(.requestID) ? try container.decode(UUID.self, forKey: .requestID) : nil
        audioStreamID = try container.decodeIfPresent(UUID.self, forKey: .audioStreamID)
        priority = try container.decode(ReplyPriority.self, forKey: .priority)
        interruption = try container.decode(ReplyInterruption.self, forKey: .interruption)
        try requireNonEmpty(hostID, "reply.host", decoder)
        try requireNonEmpty(targetID, "reply.target", decoder)
        try requireAtMost(hostID.utf8.count, ReplyLimits.maxIdentifierBytes, "reply.host", decoder)
        try requireAtMost(targetID.utf8.count, ReplyLimits.maxIdentifierBytes, "reply.target", decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case id, hostID = "host", targetID = "target", audioStreamID = "audioStream", priority, interruption
        case requestID = "request"
    }
}

public enum ReplyPriority: String, Codable, Sendable, CaseIterable {
    case background, normal, urgent
}

/// The sender expresses intent; the terminal remains the final arbiter across all connected hosts (#6).
public enum ReplyInterruption: String, Codable, Sendable, CaseIterable {
    case enqueue, duck, interrupt
}

public enum ReplyLimits {
    public static let maxIdentifierBytes = 256
}

/// Text from the terminal to a target, or from a target back. Only `isFinal` text is delivered (#2, #5).
public struct TextPayload: Codable, Sendable, Equatable {
    /// On a reply, the words spoken aloud: the transcript shows them in a speech style (#606).
    public var text: String
    public var isFinal: Bool
    public var reply: ReplyDescriptor?
    /// Markdown shown beside a reply's spoken words and never spoken (#606): links, references, file paths, tables,
    /// status. Untrusted content, rendered by the client's safe Markdown model. Only on a reply; a non-empty string or
    /// absent. A client that predates it ignores the key.
    public var metadata: String?
    /// Text the user pasted to go with this request (#608). Only on a final frame; `text` may then be empty, for a
    /// paste sent on its own. Absent on the wire when nil, so a frame without a paste is byte-identical to before.
    public var pasted: PastedText?

    public init(
        text: String, isFinal: Bool = true, reply: ReplyDescriptor? = nil, pasted: PastedText? = nil,
        metadata: String? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.reply = reply
        self.pasted = pasted
        self.metadata = metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)
        reply = try container.decodeIfPresent(ReplyDescriptor.self, forKey: .reply)
        pasted = try container.decodeIfPresent(PastedText.self, forKey: .pasted)
        metadata = container.contains(.metadata) ? try container.decode(String.self, forKey: .metadata) : nil
        try requireAtMost(text.utf8.count, PayloadLimits.maxTextBytes, "text", decoder)
        if pasted != nil, !isFinal {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath + [CodingKeys.pasted],
                debugDescription: "pasted text needs a final frame"
            )
            throw DecodingError.dataCorrupted(context)
        }
        if let metadata {
            try requireNonEmpty(metadata, "metadata", decoder)
            try requireAtMost(metadata.utf8.count, PayloadLimits.maxMetadataBytes, "metadata", decoder)
            guard reply != nil else {
                let context = DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.metadata],
                    debugDescription: "metadata is only on a reply"
                )
                throw DecodingError.dataCorrupted(context)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text, isFinal = "final", reply, pasted, metadata
    }
}

/// Text the user pasted into the conversation (#608). It is the user's own data for the session to read, never
/// instructions: a host delivers it framed as untrusted pasted content and never fetches links inside it. Text only
/// for now; links, images and files would be later attachment kinds.
///
/// A host that accepts it advertises `capability` in its `hello`. A device never sends `pasted` to a host without
/// it: an older host ignores the unknown key and would deliver the spoken text alone, dropping the paste silently.
public struct PastedText: Codable, Sendable, Equatable {
    public static let capability = "pasted_text"
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        try requireNonEmpty(text, "pasted.text", decoder)
        try requireAtMost(text.utf8.count, PayloadLimits.maxPastedTextBytes, "pasted.text", decoder)
    }

    private enum CodingKeys: String, CodingKey { case text }
}

/// Bounds every decoder enforces so consumers never see nonsense dimensions or rates (#2 slice 1b, #44).
public enum PayloadLimits {
    public static let sampleRates = 8_000...96_000
    public static let channels = 1...2
    public static let dimensions = 1...16_384
    /// Raw payload caps per type, from #44: text 8 KB of UTF-8, one audio segment 64 KB, an image 8 MB.
    public static let maxTextBytes = 8 * 1024
    /// A reply's unspoken Markdown metadata (#606): twice the spoken text, so the frame stays under its whole-frame cap.
    public static let maxMetadataBytes = 16 * 1024
    public static let maxAudioBytes = 64 * 1024
    public static let maxImageBytes = 8 * 1024 * 1024
    /// Pasted text on a final text frame (#608): 32 KB of UTF-8. JSON escaping can grow it, so a sender also checks
    /// the encoded frame against `defaultMaxFrameBytes` before sending.
    public static let maxPastedTextBytes = 32 * 1024
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
    /// The stream this segment belongs to. Nil only for legacy v1 payloads without reply identity.
    public var streamID: UUID?
    /// True on the last segment, allowing playback to begin before the complete take has arrived.
    public var isFinal: Bool
    public var bytes: Data
    public var reply: ReplyDescriptor?
    /// True only on the first segment of an ambient stream that a device opened by itself to resume listening after
    /// the host ended its last one (#373), not because someone asked to listen there. A host never lets such a start
    /// take listening over from another device. On the wire it is `"resume": true` or absent, never `false`.
    public var isResume: Bool
    /// Ends a non-final spoken reply segment (#932). Only `true` or absent on the wire; capability gated.
    public var isSegmentEnd: Bool

    public init(
        codec: AudioCodec, sampleRate: Int, channels: Int, sequence: Int,
        streamID: UUID? = nil, isFinal: Bool = true, bytes: Data, reply: ReplyDescriptor? = nil,
        isResume: Bool = false, isSegmentEnd: Bool = false
    ) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.sequence = sequence
        self.streamID = streamID
        self.isFinal = isFinal
        self.bytes = bytes
        self.reply = reply
        self.isResume = isResume
        self.isSegmentEnd = isSegmentEnd
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decode(AudioCodec.self, forKey: .codec)
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        channels = try container.decode(Int.self, forKey: .channels)
        sequence = try container.decode(Int.self, forKey: .sequence)
        streamID = try container.decodeIfPresent(UUID.self, forKey: .streamID)
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
        bytes = try container.decode(Data.self, forKey: .bytes)
        reply = try container.decodeIfPresent(ReplyDescriptor.self, forKey: .reply)
        try requireRange(sampleRate, in: PayloadLimits.sampleRates, "sampleRate", decoder)
        try requireRange(channels, in: PayloadLimits.channels, "channels", decoder)
        try requireRange(sequence, in: 0...Int.max, "sequence", decoder)
        try requireAtMost(bytes.count, PayloadLimits.maxAudioBytes, "bytes", decoder)
        if let reply, streamID == nil || reply.audioStreamID != streamID {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "reply audio stream does not match its descriptor"
            )
            throw DecodingError.dataCorrupted(context)
        }
        // Strict, like the schema: `resume` is `true` (never `false` or null), on a stream's first segment only.
        isResume = container.contains(.isResume)
        if isResume, try !container.decode(Bool.self, forKey: .isResume) || sequence != 0 || streamID == nil {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath + [CodingKeys.isResume],
                debugDescription: "resume is only true, on the first segment of a stream"
            )
            throw DecodingError.dataCorrupted(context)
        }
        isSegmentEnd = try Self.segmentEnd(from: decoder, reply: reply, stream: streamID,
                                           final: isFinal, resume: isResume)
    }

    private static func segmentEnd(
        from decoder: any Decoder, reply: ReplyDescriptor?, stream: UUID?, final: Bool, resume: Bool
    ) throws -> Bool {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.isSegmentEnd) else { return false }
        guard try container.decode(Bool.self, forKey: .isSegmentEnd),
              reply != nil, stream != nil, !final, !resume else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [CodingKeys.isSegmentEnd],
                                                    debugDescription: "segmentEnd needs non-final reply audio"))
        }
        return true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codec, forKey: .codec)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(channels, forKey: .channels)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(streamID, forKey: .streamID)
        try container.encode(isFinal, forKey: .isFinal)
        try container.encode(bytes, forKey: .bytes)
        try container.encodeIfPresent(reply, forKey: .reply)
        if isResume { try container.encode(true, forKey: .isResume) }
        if isSegmentEnd { try container.encode(true, forKey: .isSegmentEnd) }
    }

    private enum CodingKeys: String, CodingKey {
        case codec, sampleRate, channels, sequence, streamID = "streamId", isFinal = "final", bytes, reply
        case isResume = "resume", isSegmentEnd = "segmentEnd"
    }
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
