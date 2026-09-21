import Foundation
public import HailProtocol

/// The last destination explicitly authorized by the operator.
///
/// The target name is part of the remembered identity so a host cannot silently reuse a stable-looking
/// target ID for a renamed destination. Restoration only occurs after the host publishes a matching live target.
public struct DestinationSelection: Codable, Equatable, Sendable {
    public let hostID: HostEndpoint.Identifier
    public let hostURL: String
    public let targetID: String
    public let targetName: String

    public init(hostID: HostEndpoint.Identifier, hostURL: String, targetID: String, targetName: String) {
        self.hostID = hostID
        self.hostURL = hostURL
        self.targetID = targetID
        self.targetName = targetName
    }

    public func matches(endpoint: HostEndpoint) -> Bool {
        hostID == endpoint.id && hostURL == endpoint.url.absoluteString
    }

    public func matches(endpoint: HostEndpoint, target: TargetInfo) -> Bool {
        matches(endpoint: endpoint) && target.id == targetID && target.name == targetName && target.alive
    }
}

public protocol DestinationSelectionStoring: Sendable {
    func load() async -> DestinationSelection?
    func save(_ selection: DestinationSelection?) async
}

public actor UserDefaultsDestinationSelectionStore: DestinationSelectionStoring {
    private let key: String
    private let suiteName: String?

    public init(
        key: String = "hailing-station.destination-selection.v1",
        suiteName: String? = nil
    ) {
        self.key = key
        self.suiteName = suiteName
    }

    public func load() -> DestinationSelection? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DestinationSelection.self, from: data)
    }

    public func save(_ selection: DestinationSelection?) {
        guard let selection, let data = try? JSONEncoder().encode(selection) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
