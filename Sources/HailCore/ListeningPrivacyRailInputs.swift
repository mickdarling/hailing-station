/// The privacy state the rail reads (#1115): the host has no privacy switch, or the switch's own status.
public enum RailPrivacy: Equatable, Sendable {
    /// The host takes no privacy switch, so everything heard is sent.
    case unsupported
    case status(PrivacySwitchStatus)
}

/// The listening run's own connection trouble (#904), from `AmbientListeningReconnect`.
public enum RailConnection: Equatable, Sendable {
    /// The run is reconnecting (`isPending`).
    case reconnecting
    /// The run stopped. `reason` is the notice's own text.
    case stopped(reason: String)
}

/// What the host and station report for the rail (#1115). These are claims, kept apart from the device's own
/// microphone and listening switch: a claim can raise the rail to an alert, never clear a microphone that isn't off.
public struct RailHost: Equatable, Sendable {
    public var privacy: RailPrivacy?
    public var handoff: AmbientHandoff?
    public var availability: StationAvailability
    public var connection: RailConnection?

    public init(
        privacy: RailPrivacy?, handoff: AmbientHandoff?, availability: StationAvailability,
        connection: RailConnection?
    ) {
        (self.privacy, self.handoff, self.availability, self.connection) = (privacy, handoff, availability, connection)
    }
}
