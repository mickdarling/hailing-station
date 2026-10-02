public import Foundation
public import HailProtocol

// Authorization proof, admission and negotiation stay beside the private authorizer they protect.
// swiftlint:disable file_length

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

/// Proof that this session's authorizer allowed exactly one final, targeted text frame. Only `HostSession`
/// constructs it, from the frame it authorized, so `deliver` can never be reached with text, target or
/// utterance identity the authorizer did not see, and no frame is authorized twice.
struct AuthorizedInput: Sendable, Equatable {
    let text: String
    let target: String
    /// The authorized frame's own id: an authorizer keyed on frame identity sees the utterance the host gets.
    let utteranceID: UUID
    /// The authorized frame's `source`, carried to the host as the sending device.
    let device: String
    let version: Int
    /// A caller's listing pin, not part of the authorized identity; a changed binding refuses, never follows.
    var expectedBinding: String?

    fileprivate init(text: String, target: String, frame: Frame, version: Int) {
        self.text = text
        self.target = target
        utteranceID = frame.id
        device = frame.source
        self.version = version
    }
}

/// One authorizer decision per frame, taken exactly once. The allowed frame is classified here so routing
/// answers each shape exactly as before without consulting the authorizer again.
enum AdmittedFrame: Sendable {
    case control(ControlPayload)
    case input(AuthorizedInput)
    case nonFinalText
    case untargetedText
    case unsupported
}

public struct HostSessionResult: Sendable, Equatable {
    public var frames: [Frame]
    public var disposition: HostSessionDisposition

    public init(frames: [Frame], disposition: HostSessionDisposition = .keepOpen) {
        self.frames = frames
        self.disposition = disposition
    }
}

/// One peer's protocol state. Every path to `HailHost.send` runs through this session's authorizer exactly
/// once per frame and through its captured selection: `deliver` accepts only an `AuthorizedInput`, which
/// only the authorizer's own allow decision on that frame can produce.
public actor HostSession {
    enum State: Sendable, Equatable {
        case awaitingHello
        case ready(version: Int)
        case closed
    }

    public static let capabilities = ["connection_probe", "list_targets", "ping"]

    let host: HailHost
    private let authorizer: any HostSessionAuthorizing
    let hostName: String
    let now: @Sendable () -> Int64
    let requestClock: @Sendable () -> ContinuousClock.Instant
    var state = State.awaitingHello
    var peerName = "terminal"
    var selectedTarget: String?
    let connectionID = UUID()
    var selectionGeneration = UUID()
    var replyRequests: [UUID: HostReplyRequest] = [:]

    public init(
        host: HailHost, authorizer: any HostSessionAuthorizing = ConnectionProbeAuthorizer(),
        hostName: String = "haild",
        now: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        requestClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.host = host
        self.authorizer = authorizer
        self.hostName = hostName
        self.now = now
        self.requestClock = requestClock
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
            guard let admitted = await admit(frame, version: version) else {
                return failure(.unauthorized, "terminal action is not authorized", close: false, version: version)
            }
            return await route(admitted, version: version)
        }
    }

    /// The single authorizer call for `frame`. An allowed final targeted text frame becomes the only
    /// `AuthorizedInput` that frame will ever yield; `deliver` accepts nothing else.
    private func admit(_ frame: Frame, version: Int) async -> AdmittedFrame? {
        guard await authorizer.authorize(frame) == .allow else { return nil }
        switch frame.payload {
        case .control(let control): return .control(control)
        case .text(let text):
            guard text.isFinal else { return .nonFinalText }
            guard let target = frame.target else { return .untargetedText }
            return .input(AuthorizedInput(text: text.text, target: target, frame: frame, version: version))
        default: return .unsupported
        }
    }

    /// Authorization for an ingress path that does not arrive over the socket (#188 local dispatch): the
    /// caller builds the exact frame it wants delivered and gets back the proof, or nothing. Only a
    /// negotiated session answers, and the frame must speak the negotiated version.
    func authorize(_ frame: Frame) async -> AuthorizedInput? {
        guard case .ready(let version) = state, frame.version == version,
              case .input(let input)? = await admit(frame, version: version) else { return nil }
        return input
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
        if close {
            state = .closed
            replyRequests.removeAll()
        }
        return HostSessionResult(
            frames: [response(.error(code: code, message: message), version: version)],
            disposition: close ? .close : .keepOpen
        )
    }
}
