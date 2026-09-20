import HailProtocol

/// Build facts the daemon reports from `haild status` and doctor (#10, #34, #46).
public enum DaemonInfo {
    public static let version = "0.1.0"
    public static let protocolVersion = ProtocolVersion.current

    /// One line for humans and the launch log.
    public static var banner: String {
        "haild \(version) protocol v\(protocolVersion)"
    }
}
