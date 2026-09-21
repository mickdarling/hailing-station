public import Foundation
public import HailProtocol

/// The authorization decision is separate from framing and routing so authenticated sessions can replace
/// the read-only probe without replacing the WebSocket listener (#98, then #39/#40).
public enum HostSessionAuthorization: Sendable, Equatable {
    case allow
    case deny
}

public protocol HostSessionAuthorizing: Sendable {
    var capabilities: [String] { get }
    func authorize(_ frame: Frame) async -> HostSessionAuthorization
}

/// The temporary connection proof can negotiate and inspect liveness, but it grants no target authority.
public struct ConnectionProbeAuthorizer: HostSessionAuthorizing {
    public init() {}
    public let capabilities = ["connection_probe", "list_targets", "ping"]

    public func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        guard case .control(let control) = frame.payload else { return .deny }
        switch control {
        case .hello, .ping, .listTargets: return .allow
        default: return .deny
        }
    }
}

/// Explicitly enabled personal-testing mode. It exposes only target selection, final text delivery,
/// and literal Escape in addition to the probe operations; the default listener remains read-only.
public struct PersonalTerminalAuthorizer: HostSessionAuthorizing {
    public init() {}
    public let capabilities = ["list_targets", "ping", "select_target", "send_text", "escape", "receive_replies"]

    public func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        switch frame.payload {
        case .text(let text): text.isFinal ? .allow : .deny
        case .control(let control):
            switch control {
            case .hello, .ping, .listTargets, .select, .escape: .allow
            default: .deny
            }
        default: .deny
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
    enum State: Sendable, Equatable {
        case awaitingHello
        case ready(version: Int)
        case closed
    }

    public static let capabilities = ["connection_probe", "list_targets", "ping"]

    let host: HailHost
    private let authorizer: any HostSessionAuthorizing
    private let hostName: String
    private let now: @Sendable () -> Int64
    private var state = State.awaitingHello
    var peerName = "terminal"
    var selectedTarget: String?
    var acceptedAudioStreams: [UUID: ReplyDescriptor] = [:]

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
                return failure(.unauthorized, "terminal action is not authorized", close: false, version: version)
            }
            return await route(frame, version: version)
        }
    }

    /// Host-originated replies are pushed only after negotiation and only to the target this terminal selected.
    /// Reply identity/provenance has already been validated by the listener's publication boundary.
    func acceptsHostReply(_ frame: Frame) -> Bool {
        guard case .ready(let version) = state, frame.version == version else { return false }
        return switch frame.payload {
        case .text(let text):
            text.isFinal && text.reply != nil && frame.target == selectedTarget
        case .audio(let audio):
            acceptsHostAudio(audio, target: frame.target)
        default: false
        }
    }

    private func acceptsHostAudio(_ audio: AudioPayload, target: String?) -> Bool {
        guard let reply = audio.reply, let streamID = audio.streamID else { return false }
        if audio.sequence == 0 {
            guard target == selectedTarget else { return false }
            acceptedAudioStreams[streamID] = reply
        } else {
            guard acceptedAudioStreams[streamID] == reply else { return false }
        }
        if audio.isFinal { acceptedAudioStreams[streamID] = nil }
        return true
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
        peerName = hello.deviceName
        let info = HelloInfo(
            versions: VersionNegotiation.supported,
            capabilities: authorizer.capabilities,
            deviceName: hostName
        )
        return HostSessionResult(frames: [response(.hello(info), version: version)])
    }

    func response(_ control: ControlPayload, version: Int) -> Frame {
        Frame(version: version, timestamp: now(), source: "haild", payload: .control(control))
    }
    func failure(
        _ code: ErrorCode, _ message: String, close: Bool, version: Int = ProtocolVersion.current
    ) -> HostSessionResult {
        if close { state = .closed }
        return HostSessionResult(
            frames: [response(.error(code: code, message: message), version: version)],
            disposition: close ? .close : .keepOpen
        )
    }
}
