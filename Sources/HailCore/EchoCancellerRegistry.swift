public enum EchoPlatform: CaseIterable, Sendable {
    case mac, iPhone, iPad, iPadAppOnMac
}

/// Classify the actual output after activation. A transport name alone cannot establish private listening.
public enum EchoRouteClass: Sendable {
    case roomSpeaker, roomHandsFree, otherRoomOutput, verifiedPrivateHeadphones, unknown
}

public struct EchoCancellerConfiguration: Sendable {
    public var identifiers: [EchoPlatform: [EchoRouteClass: String]]

    public init(identifiers: [EchoPlatform: [EchoRouteClass: String]]) {
        self.identifiers = identifiers
    }

    public static let standard: Self = {
        func routes(room: String) -> [EchoRouteClass: String] {
            [.roomSpeaker: room, .roomHandsFree: room, .otherRoomOutput: room, .verifiedPrivateHeadphones: "none"]
        }
        let desktop = routes(room: "aec3")
        let mobile = routes(room: "apple-voice-processing")
        return Self(identifiers: [.mac: desktop, .iPadAppOnMac: desktop, .iPhone: mobile, .iPad: mobile])
    }()
}

/// Dispatch on the processing capability, independent of the configured identifier.
public enum EchoCancellerImplementation {
    case frames(any FrameEchoCanceller)
    case inGraph(any GraphEchoCanceller)
}

public enum EchoCancellerResolution {
    case implementation(EchoCancellerImplementation)
    /// No implementation is safe to use for this selection. Send masked samples.
    case mask(EchoCancellerError)
}

public struct EchoCancellerRegistry {
    /// Each invocation must create a fresh instance for one capture run.
    public typealias Factory = () -> EchoCancellerImplementation
    private var factories: [String: Factory] = [
        "none": { .frames(PassthroughEchoCanceller()) },
        "apple-voice-processing": { .inGraph(AppleVoiceProcessingDescriptor()) }
    ]

    public init() {}

    public mutating func register(_ identifier: String, factory: @escaping Factory) {
        factories[identifier] = factory
    }

    public func resolve(platform: EchoPlatform, route: EchoRouteClass,
                        configuration: EchoCancellerConfiguration = .standard) -> EchoCancellerResolution {
        guard route != .unknown else { return .mask(.unconfiguredRoute) }
        guard let identifier = configuration.identifiers[platform]?[route] else { return .mask(.unconfiguredRoute) }
        guard let factory = factories[identifier] else { return .mask(.unregisteredImplementation) }
        return .implementation(factory())
    }
}
