/// The payload kinds a frame can carry. `image`, `frame`, and `control` are reserved in v1 (#2, #16).
public enum FrameType: String, Codable, Sendable, CaseIterable {
    case text
    case audio
    case image
    case frame
    case control
}
