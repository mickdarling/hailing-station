public import Foundation
public import HailProtocol

/// The authorization decision is separate from framing and routing so authenticated sessions can replace
/// the read-only probe without replacing the WebSocket listener (#98, then #39/#40).
public enum HostSessionAuthorization: Sendable, Equatable {
    case allow
    case deny
}

public protocol HostSessionAuthorizing: Sendable {
    func authorize(_ frame: Frame) async -> HostSessionAuthorization
}

/// The temporary connection proof can negotiate and inspect liveness, but it grants no target authority.
public struct ConnectionProbeAuthorizer: HostSessionAuthorizing {
    public init() {}

    public func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        guard case .control(let control) = frame.payload else { return .deny }
        switch control {
        case .hello, .ping, .listTargets: return .allow
        default: return .deny
        }
    }
}

public enum HostSessionDisposition: Sendable, Equatable {
    case keepOpen
    case close
}

public struct HostSessionResult: Sendable, Equatable {
    public var frames: [Frame]
    public var disposition: HostSessionDisposition

    public init(frames: [Frame], disposition: HostSessionDisposition = .keepOpen) {
        self.frames = frames
        self.disposition = disposition
    }
}

/// One peer's protocol state. It deliberately has no delivery method: a probe session cannot reach
/// `HailHost.send`, even if a caller constructs action-bearing frames directly.
public actor HostSession {
    private enum State: Sendable, Equatable {
        case awaitingHello
        case ready(version: Int)
        case closed
    }

    public static let capabilities = ["connection_probe", "list_targets", "ping"]

    private let host: HailHost
    private let authorizer: any HostSessionAuthorizing
    private let hostName: String
    private let now: @Sendable () -> Int64
    private var state = State.awaitingHello

    public init(
        host: HailHost, authorizer: any HostSessionAuthorizing = ConnectionProbeAuthorizer(),
        hostName: String = "haild",
        now: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        }
    ) {
        self.host = host
        self.authorizer = authorizer
        self.hostName = hostName
        self.now = now
    }

    /// Applies the whole-frame bound before JSON decoding. Listener options enforce the same bound at the
    /// network layer; keeping it here makes non-network callers and tests follow the identical rule.
    public func receive(_ data: Data) async -> HostSessionResult {
        do {
            return await receive(try FrameCoding.decode(data))
        } catch {
            return failure(.malformed, "malformed or oversized frame", close: true)
        }
    }

    public func receive(_ frame: Frame) async -> HostSessionResult {
        switch state {
        case .closed:
            return HostSessionResult(frames: [], disposition: .close)
        case .awaitingHello:
            return await negotiate(frame)
        case .ready(let version):
            guard frame.version == version else {
                return failure(.protocolVersion, "frame version does not match the session", close: true)
            }
            guard await authorizer.authorize(frame) == .allow else {
                return failure(.unauthorized, "connection probe is read-only", close: false, version: version)
            }
            return await route(frame, version: version)
        }
    }

    private func negotiate(_ frame: Frame) async -> HostSessionResult {
        guard case .control(.hello(let hello)) = frame.payload else {
            return failure(.malformed, "first frame must be hello", close: true)
        }
        guard await authorizer.authorize(frame) == .allow else {
            return failure(.unauthorized, "hello is not authorized", close: true)
        }
        guard hello.versions.contains(frame.version),
              let version = VersionNegotiation.choose(offered: hello.versions) else {
            return failure(.protocolVersion, "no shared protocol version", close: true)
        }
        state = .ready(version: version)
        let info = HelloInfo(
            versions: VersionNegotiation.supported,
            capabilities: Self.capabilities,
            deviceName: hostName
        )
        return HostSessionResult(frames: [response(.hello(info), version: version)])
    }

    private func route(_ frame: Frame, version: Int) async -> HostSessionResult {
        guard case .control(let control) = frame.payload else {
            return failure(.unauthorized, "connection probe is read-only", close: false, version: version)
        }
        switch control {
        case .ping(let nonce):
            return HostSessionResult(frames: [response(.pong(nonce: nonce), version: version)])
        case .listTargets:
            do {
                let targets = try await policyFilteredTargets()
                return HostSessionResult(frames: [response(.targets(targets), version: version)])
            } catch {
                return failure(.malformed, "target listing unavailable", close: false, version: version)
            }
        case .hello:
            return failure(.malformed, "hello already received", close: true, version: version)
        default:
            return failure(.unauthorized, "connection probe is read-only", close: false, version: version)
        }
    }

    private func policyFilteredTargets() async throws -> [TargetInfo] {
        let listing = try await host.registry.listing()
        guard await host.policyFailure == nil else { return [] }
        let policy = await host.currentPolicy
        return listing.compactMap { listed in
            guard let allowed = policy.targets[listed.info.id], allowed.binding == listed.binding else { return nil }
            return listed.info
        }
    }
    private func response(_ control: ControlPayload, version: Int) -> Frame {
        Frame(version: version, timestamp: now(), source: "haild", payload: .control(control))
    }
    private func failure(
        _ code: ErrorCode, _ message: String, close: Bool, version: Int = ProtocolVersion.current
    ) -> HostSessionResult {
        if close { state = .closed }
        return HostSessionResult(
            frames: [response(.error(code: code, message: message), version: version)],
            disposition: close ? .close : .keepOpen
        )
    }
}
public enum ConnectionProbeDaemon {
    public static func run(
        host: HailHost, arguments: [String], hostName: String,
        log: @escaping @Sendable (WebSocketListenerEvent) -> Void
    ) async throws {
        var address: String?
        var port: UInt16?
        var probe = false
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            switch flag {
            case "--bind": address = rest.popFirst()
            case "--port":
                if let value = rest.popFirst(), let parsed = UInt16(value), parsed > 0 { port = parsed }
            case "--connection-probe": probe = true
            default: throw WebSocketListenerError.invalidArguments
            }
        }
        guard let address, let port, probe else { throw WebSocketListenerError.invalidArguments }
        let listener = try WebSocketListener(
            bindAddress: address, port: port, host: host, hostName: hostName, log: log
        )
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .utility))
        termination.setEventHandler { Task { await listener.stop(reason: "SIGTERM") } }
        interruption.setEventHandler { Task { await listener.stop(reason: "SIGINT") } }
        termination.resume()
        interruption.resume()
        defer {
            termination.cancel()
            interruption.cancel()
        }
        _ = try await listener.start()
        await listener.waitUntilStopped()
    }
}
