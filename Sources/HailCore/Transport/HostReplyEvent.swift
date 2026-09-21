public import HailProtocol

/// One validated reply frame received from a specific configured Mac connection.
///
/// `endpointID` is local configuration identity; the frame's reply descriptor carries the
/// protocol-level host, target, reply, and audio-stream identities used for arbitration.
public struct HostReplyEvent: Equatable, Sendable {
    public var endpointID: HostEndpoint.Identifier
    public var frame: Frame

    public init(endpointID: HostEndpoint.Identifier, frame: Frame) {
        self.endpointID = endpointID
        self.frame = frame
    }
}
