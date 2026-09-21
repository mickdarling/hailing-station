public import Foundation
public import HailProtocol

/// Stable configuration for one Mac. Runtime connection state is keyed by `id`, never by display order or name.
public struct HostEndpoint: Codable, Hashable, Identifiable, Sendable {
    public typealias Identifier = String

    public let id: Identifier
    public var name: String
    public var url: URL

    public init(id: Identifier = UUID().uuidString.lowercased(), name: String, url: URL) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedName.isEmpty,
              let scheme = url.scheme?.lowercased(), ["ws", "wss"].contains(scheme),
              url.host() != nil else {
            throw HostEndpointError.invalidEndpoint
        }
        self.id = trimmedID
        self.name = trimmedName
        self.url = url
    }
}

public protocol WebSocketTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public protocol WebSocketConnecting: Sendable {
    func open(url: URL, subprotocol: String) async throws -> any WebSocketTransport
}

/// The production seam around URLSessionWebSocketTask. Tests provide scripted transports through the same protocol.
public struct URLSessionWebSocketConnector: WebSocketConnecting {
    public init() {}

    public func open(url: URL, subprotocol: String) async throws -> any WebSocketTransport {
        var request = URLRequest(url: url)
        request.setValue(subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionSocket(session: session, task: task)
    }
}

private actor URLSessionSocket: WebSocketTransport {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    func send(_ data: Data) async throws { try await task.send(.data(data)) }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw HostConnectionFailure.malformed("unsupported WebSocket message")
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

public enum HostEndpointError: Error, Equatable, Sendable {
    case invalidEndpoint
}

/// The visible lifecycle of one host. A ready connection means transport health, never delivery confirmation.
public enum HostConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case negotiating
    case ready
    case reconnecting(attempt: Int, nextDelay: TimeInterval)
    case failed(reason: String)
}

/// Observable data emitted by a connection. It contains diagnostics and target metadata, never transcript content.
public struct HostConnectionSnapshot: Equatable, Identifiable, Sendable {
    public var endpoint: HostEndpoint
    public var connectionGeneration: UInt64
    public var state: HostConnectionState
    public var negotiatedVersion: Int?
    public var capabilities: [String]
    public var lastPingMilliseconds: Double?
    public var targets: [TargetInfo]
    public var receivedTargetList: Bool

    public var id: HostEndpoint.Identifier { endpoint.id }

    public init(
        endpoint: HostEndpoint,
        connectionGeneration: UInt64 = 0,
        state: HostConnectionState = .disconnected,
        negotiatedVersion: Int? = nil,
        capabilities: [String] = [],
        lastPingMilliseconds: Double? = nil,
        targets: [TargetInfo] = [],
        receivedTargetList: Bool = false
    ) {
        self.endpoint = endpoint
        self.connectionGeneration = connectionGeneration
        self.state = state
        self.negotiatedVersion = negotiatedVersion
        self.capabilities = capabilities
        self.lastPingMilliseconds = lastPingMilliseconds
        self.targets = targets
        self.receivedTargetList = receivedTargetList
    }
}

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

/// Bounded exponential reconnect timing. Jitter spans ±20 percent around the base delay.
public struct ReconnectSchedule: Equatable, Sendable {
    public let baseDelays: [TimeInterval]

    public init(baseDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]) {
        precondition(!baseDelays.isEmpty && baseDelays.allSatisfy { $0 > 0 })
        self.baseDelays = baseDelays
    }

    public func delay(attempt: Int, jitterUnit: Double) -> TimeInterval {
        let index = min(max(attempt - 1, 0), baseDelays.count - 1)
        let unit = min(max(jitterUnit, 0), 1)
        return baseDelays[index] * (0.8 + (0.4 * unit))
    }
}
