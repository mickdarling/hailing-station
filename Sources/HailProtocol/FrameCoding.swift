public import Foundation

/// The one JSON dialect both ends use: sorted keys so fixtures are stable, base64 for bytes, no pretty printing.
public enum FrameCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encode(_ frame: Frame) throws -> Data {
        try encoder().encode(frame)
    }

    /// Thrown before any parsing when the input exceeds `maxBytes`. Size is checked first so a hostile
    /// peer cannot make the decoder inflate a large base64 blob (#44, #47).
    public struct FrameTooLarge: Error, Equatable, Sendable {
        public let size: Int
        public let limit: Int
    }

    public static func decode(_ data: Data, maxBytes: Int = PayloadLimits.defaultMaxFrameBytes) throws -> Frame {
        guard data.count <= maxBytes else { throw FrameTooLarge(size: data.count, limit: maxBytes) }
        return try decoder().decode(Frame.self, from: data)
    }
}
