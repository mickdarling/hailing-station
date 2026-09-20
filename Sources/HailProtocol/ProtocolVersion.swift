/// The hail frame protocol version. Bumped by #2 and by any later change to a `Codable` frame type (#28).
public enum ProtocolVersion {
    /// The version this build speaks.
    public static let current = 1
}
