public import Foundation

/// Local paths for `haild coaching` (#645), read from a small JSON file the owner writes. The card never shows or
/// logs these paths. Parsing checks shape only; haild re-validates every file before it starts anything.
///
/// ```json
/// { "haild": "/abs/haild", "rightyo": "/abs/rightyo", "rightyoConfig": "/abs/config",
///   "listenerProfile": "/abs/profile", "listener": "owner", "rendererOutputRoot": "/abs/dir",
///   "hosted": { "maxRequests": 20, "adviceCatalog": "/abs/catalog" } }
/// ```
/// `hosted` is optional. Without it only the local mock provider is offered.
public struct PrivateCoachingSetup: Sendable, Equatable, Decodable {
    public struct Hosted: Sendable, Equatable, Decodable {
        public let maxRequests: Int
        public let adviceCatalog: String
    }

    public enum Provider: Sendable, Equatable { case local, hosted }

    public enum SetupError: Error, Equatable { case invalid, hostedNotConfigured, hostedConsentRequired }

    public let haild: String
    public let rightyo: String
    public let rightyoConfig: String
    public let listenerProfile: String
    public let listener: String
    public let rendererOutputRoot: String
    public let hosted: Hosted?

    /// The file must be small, decode exactly, and carry only absolute paths and a listener ID haild accepts.
    public static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4_096,
              let setup = try? JSONDecoder().decode(Self.self, from: data) else { throw SetupError.invalid }
        let paths = [setup.haild, setup.rightyo, setup.rightyoConfig, setup.listenerProfile,
                     setup.rendererOutputRoot] + (setup.hosted.map { [$0.adviceCatalog] } ?? [])
        guard paths.allSatisfy(absolutePath), CoachingWireAdvice.identifier(setup.listener) else {
            throw SetupError.invalid
        }
        if let hosted = setup.hosted, !(1...100).contains(hosted.maxRequests) { throw SetupError.invalid }
        return setup
    }

    public var offersHosted: Bool { hosted != nil }

    /// Arguments after the haild executable. The hosted flags appear only with the hosted provider AND its consent.
    /// Device numbers are fresh HAL IDs from the inventory; haild re-reads their OS evidence before binding.
    public func arguments(privateOutput: UInt32, roomMicrophone: UInt32, provider: Provider,
                          hostedConsentConfirmed: Bool) throws -> [String] {
        guard privateOutput > 0, roomMicrophone > 0, privateOutput != roomMicrophone else {
            throw SetupError.invalid
        }
        var arguments = ["coaching", "--parent-control",
                         "--rightyo", rightyo, "--rightyo-config", rightyoConfig,
                         "--listener-profile", listenerProfile, "--listener", listener,
                         "--private-output", String(privateOutput), "--room-microphone", String(roomMicrophone),
                         "--renderer-output-root", rendererOutputRoot]
        guard provider == .hosted else { return arguments }
        guard let hosted else { throw SetupError.hostedNotConfigured }
        guard hostedConsentConfirmed else { throw SetupError.hostedConsentRequired }
        arguments += ["--coaching-provider", "jev", "--coaching-allow-hosted-text",
                      "--coaching-max-requests", String(hosted.maxRequests),
                      "--coaching-advice-catalog", hosted.adviceCatalog]
        return arguments
    }

    private static func absolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.count <= 1_024 && !value.contains("\0") && !value.contains("\n")
    }
}
