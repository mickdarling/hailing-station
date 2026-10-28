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
    /// The daemon's ambient audio gate when ambient listening was explicitly enabled (#203); nil otherwise.
    var ambientAudio: AmbientAudioGate? { get }
    /// The device diagnostics sink when haild runs with `--device-diagnostics` (#234); nil otherwise.
    var diagnostics: DiagnosticLog? { get }
    /// The host's read-only health summary when haild runs with `--host-health` (#614); nil otherwise.
    var health: (@Sendable () async -> HostHealth)? { get }
    #if os(macOS)
    /// The owner's named voice routes when haild runs with `--voice-routes` (#636), which requires the file; nil otherwise.
    var voiceRoutes: VoiceRoutes? { get }
    #endif
    /// Must be free of side effects and give the same answer for the same frame: the session may ask about one frame
    /// more than once (voice routing asks about the frame as sent, then as delivered, #636).
    func authorize(_ frame: Frame) async -> HostSessionAuthorization
}

extension HostSessionAuthorizing {
    public var ambientAudio: AmbientAudioGate? { nil }
    public var diagnostics: DiagnosticLog? { nil }
    public var health: (@Sendable () async -> HostHealth)? { nil }
    #if os(macOS)
    public var voiceRoutes: VoiceRoutes? { nil }
    #endif
}

/// The temporary connection proof can negotiate and inspect liveness, but it grants no target authority.
public struct ConnectionProbeAuthorizer: HostSessionAuthorizing {
    public init() {}
    public let capabilities = ["connection_probe", "list_targets", "ping"]

    public func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        guard case .control(let control) = frame.payload else { return .deny }
        switch control {
        case .hello, .ping, .listTargets, .replyYield: return .allow
        default: return .deny
        }
    }
}

/// Explicitly enabled personal-testing mode. It exposes only target selection, final text delivery,
/// and literal Escape in addition to the probe operations; the default listener remains read-only.
/// Ambient audio (#203) is admitted, and `stream_audio` advertised, only when a gate is supplied; so is a device's
/// `overheard_scope` (#398), with `ambient_overheard` advertised, its `ambient_input` route kind (rightyo#164),
/// with `ambient_input_route` advertised, and its privacy switch (#735 S-6), with `set_privacy` advertised. Device
/// diagnostics (#234) are admitted, and `device_diagnostics` advertised, only when a sink is supplied; so is a
/// `health` request (#614), with `host_health` advertised, only when a summary is supplied. A final text
/// frame may carry a paste (#608, `pasted_text`), which is framed as untrusted data before delivery.
public struct PersonalTerminalAuthorizer: HostSessionAuthorizing {
    public let capabilities: [String]
    public let ambientAudio: AmbientAudioGate?
    public let diagnostics: DiagnosticLog?
    public let health: (@Sendable () async -> HostHealth)?

    public init(
        ambientAudio: AmbientAudioGate? = nil, diagnostics: DiagnosticLog? = nil,
        health: (@Sendable () async -> HostHealth)? = nil
    ) {
        self.ambientAudio = ambientAudio
        self.diagnostics = diagnostics
        self.health = health
        capabilities = ["list_targets", "ping", "select_target", "send_text", "escape", "receive_replies",
                        PastedText.capability]
            + (ambientAudio == nil ? [] : ["stream_audio", AmbientOverheard.capability, AmbientInput.capability,
                                           DuckMode.privacySwitchCapability])
            + (diagnostics == nil ? [] : [DiagnosticLimits.capability, DiagnosticLimits.streamAbandonedCapability])
            + (health == nil ? [] : [HostHealth.capability])
    }

    #if os(macOS)
    public private(set) var voiceRoutes: VoiceRoutes?

    /// The same authorizer with the owner's voice routes (#636). Routes grant nothing and change no capability: the
    /// listing shows their names and offline state, and every route still needs its own target policy and binding.
    public func naming(_ routes: VoiceRoutes?) -> Self {
        var named = self
        named.voiceRoutes = routes
        return named
    }
    #endif

    public func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        switch frame.payload {
        case .text(let text): text.isFinal ? .allow : .deny
        case .audio: ambientAudio == nil ? .deny : .allow
        case .control(let control):
            switch control {
            case .hello, .ping, .listTargets, .select, .escape, .replyYield: .allow
            case .diagnostic: diagnostics == nil ? .deny : .allow
            case .overheardScope, .ambientInput, .setPrivacy: ambientAudio == nil ? .deny : .allow
            case .health: health == nil ? .deny : .allow
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
/// utterance identity the authorizer did not see. It is noncopyable and `deliver` consumes it: one
/// decision admits one handoff, never a replay.
struct AuthorizedInput: ~Copyable, Sendable {
    let text: String
    let target: String
    /// The authorized frame's own id: an authorizer keyed on frame identity sees the utterance the host gets.
    let utteranceID: UUID
    /// The session's attribution of the sender (its negotiated Hello name, or a fixed local constant);
    /// never the frame's own `source`, which a client controls per frame.
    let device: String
    let version: Int
    /// A caller's listing pin, not part of the authorized identity; a changed binding refuses, never follows.
    var expectedBinding: String?
    /// True when `text` is a spoken request framed with a paste by `PastedContent` (#608): the host then applies the
    /// paste line cap, and nothing else changes.
    let carriesPaste: Bool

    fileprivate init(
        text: String, target: String, frame: Frame, device: String, version: Int, carriesPaste: Bool = false
    ) {
        self.text = text
        self.carriesPaste = carriesPaste
        self.target = target
        utteranceID = frame.id
        self.device = device
        self.version = version
    }
}

/// One admitting authorizer decision per frame. The allowed frame is classified here so routing answers each shape
/// exactly as before without consulting the authorizer again. (Voice routing, #636, also asks the authorizer about
/// the frame as sent before choosing a route, so `authorize` must have no side effects.)
enum AdmittedFrame: ~Copyable, Sendable {
    case control(ControlPayload)
    case input(AuthorizedInput)
    case nonFinalText
    case untargetedText
    /// A paste `PastedContent` refused (#608), with the plain reason for the device; nothing is delivered.
    case refusedPaste(String)
    /// A paste while the host is in lockdown (#665 review): answered as lockdown, before any framing, as speech is.
    case lockedDownPaste
    /// An ambient segment the authorizer allowed; the gate still checks shape, target, sequence and rate.
    case audio(AudioPayload, target: String?)
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

/// A snapshot-capable owner's off: refused, an armed switch exit, or parks cleared without an arming.
public enum ModeSnapshotPrivacyOff: Sendable, Equatable {
    case refused, armed, cleared
}

/// One peer's protocol state. Every path to `HailHost.send` runs through this session's authorizer and its captured
/// selection: `deliver` accepts only an `AuthorizedInput`, which only the authorizer's own allow decision on that
/// (possibly voice-routed) frame can produce. `authorize` must be free of side effects: a frame to a selected voice
/// route is asked about twice, once as sent and once as delivered (#636).
public actor HostSession {
    enum State: Sendable, Equatable {
        case awaitingHello
        case ready(version: Int)
        case closed
    }

    public static let capabilities = ["connection_probe", "list_targets", "ping", ReplySegments.capability,
                                      ModeSnapshot.capability]

    /// Listener-owned state readers; absent for callers without ambient wiring. The off callback checks the
    /// live peer before clearing parks, so teardown and shutdown cannot authorize a late snapshot switch.
    let snapshot: @Sendable (UUID) -> [ControlPayload]
    let snapshotOff: (@Sendable (UUID) async -> ModeSnapshotPrivacyOff)?
    let host: HailHost
    let authorizer: any HostSessionAuthorizing
    let hostName: String
    let now: @Sendable () -> Int64
    let requestClock: @Sendable () -> ContinuousClock.Instant
    /// Whether something reports this session's provider turns ended (#430). Until a turn-end source is wired, a
    /// provider-owned request keeps the ordinary lifetime so finished turns cannot hold capacity for hours.
    let providerTurnEndsReported: Bool
    var state = State.awaitingHello
    var peerName = "terminal"
    /// What the device said it can do in its hello (#309), bounded; it gates host-sent `stop_playback`.
    var peerCapabilities: Set<String> = []
    /// The device class its hello gave (#366), already checked against `AmbientTakeOver.deviceKinds`; or nil.
    var peerDeviceKind: String?
    /// Replies whose audio is reaching this connection and has not finished, oldest first, and replies stopped
    /// mid-stream whose remaining frames are refused (#309). Both bounded, ids only.
    var repliesInFlight: [UUID] = []
    var stoppedReplies: [UUID] = []
    /// Subset of in-flight replies with a segment boundary actually enqueued to this capable peer.
    var segmentedReplies: Set<UUID> = []
    var recordStoppedReply: @Sendable (UUID) -> Void = { _ in }
    var replyEvent: @Sendable (WebSocketListenerEvent) -> Void = { _ in }
    var selectedTarget: String?
    /// Which overheard turns this connection asked for (#398), one of `AmbientOverheard.scopes`. Every connection
    /// starts at `off`, so nothing overheard is sent until the device asks on this connection.
    var overheardScope = "off"
    let connectionID = UUID()
    var selectionGeneration = UUID()
    var replyRequests: [UUID: HostReplyRequest] = [:]
    /// The late record each uncommitted request evicted at capacity (#430), keyed by that request, so a refusal
    /// before commit can give it back (#723). An entry lives only while its handoff is in flight.
    var evictedForHandoff: [UUID: (id: UUID, request: HostReplyRequest)] = [:]
    /// The listener's last-input ledger (#370), written only at an admitted, delivered handoff; nil records nothing.
    var lastInputLedger: LastInputLedger?

    public init(
        host: HailHost, authorizer: any HostSessionAuthorizing = ConnectionProbeAuthorizer(),
        hostName: String = "haild",
        now: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        requestClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        providerTurnEndsReported: Bool = false,
        modeSnapshot: @escaping @Sendable (UUID) -> [ControlPayload] = { _ in
            [.duckMode(on: false), .mediaMode(on: false)]
        },
        snapshotPrivacyOff: (@Sendable (UUID) async -> ModeSnapshotPrivacyOff)? = nil
    ) {
        snapshot = modeSnapshot
        snapshotOff = snapshotPrivacyOff
        self.host = host
        self.providerTurnEndsReported = providerTurnEndsReported
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
            // A named route (#636) is chosen before authorization, so the authorizer sees the frame delivered.
            switch await voiceRoute(frame) {
            case .refused(let code, let message):
                return failure(code, message, close: false, version: version)
            case .deliver(let frame, let routed):
                return await Self.$voiceRouted.withValue(routed) {
                    await receiveReady(frame, version: version)
                }
            }
        }
    }

    /// The admitting authorizer call for `frame`. An allowed final targeted text frame becomes the only
    /// `AuthorizedInput` that frame will ever yield; `deliver` accepts nothing else. `device` is the
    /// session's attribution of the sender and is supplied by the session, not read from the frame.
    private func admit(_ frame: Frame, version: Int, device: String) async -> AdmittedFrame? {
        guard await authorizer.authorize(frame) == .allow else { return nil }
        switch frame.payload {
        case .control(let control): return .control(control)
        case .text(let text):
            guard text.isFinal else { return .nonFinalText }
            guard let target = frame.target else { return .untargetedText }
            guard let pasted = text.pasted else {
                return .input(AuthorizedInput(
                    text: text.text, target: target, frame: frame, device: device, version: version
                ))
            }
            return await admitPaste(pasted, spoken: text.text, frame: frame, device: device, version: version)
        case .audio(let audio): return .audio(audio, target: frame.target)
        default: return .unsupported
        }
    }

    /// A final text frame with a paste (#608). Lockdown is checked first, so a paste during lockdown hears lockdown,
    /// never a paste-specific reason. The paste is framed here, once, so the authorized text is exactly the line the
    /// host sanitises, and within what the target's adapter takes (the id's kind prefix), so an oversized paste says
    /// so. Only a known agent session takes a paste: a raw shell pane never does, and an unknown kind is refused.
    private func admitPaste(
        _ pasted: PastedText, spoken: String, frame: Frame, device: String, version: Int
    ) async -> AdmittedFrame {
        guard let target = frame.target else { return .untargetedText }
        if await host.currentLockdown.isOn { return .lockedDownPaste }
        let kind = String(target.prefix { $0 != ":" })
        guard PastedContent.acceptsPaste(targetKind: kind) else { return .refusedPaste(PastedContent.agentOnlyRefusal) }
        do {
            let limit = PastedContent.maxFramedBytes(forTargetKind: kind)
            return .input(AuthorizedInput(
                text: try PastedContent.frame(spoken: spoken, pasted: pasted.text, limit: limit),
                target: target, frame: frame, device: device, version: version, carriesPaste: true
            ))
        } catch {
            return .refusedPaste(PastedContent.refusal(error))
        }
    }

    /// Authorization for an ingress path that does not arrive over the socket (#188 local dispatch): the
    /// caller builds the exact frame it wants delivered, names the fixed device it attributes it to, and
    /// gets back the proof, or nothing. Only a negotiated session answers, and the frame must speak the
    /// negotiated version.
    func authorize(_ frame: Frame, device: String) async -> AuthorizedInput? {
        guard case .ready(let version) = state, frame.version == version else { return nil }
        switch await admit(frame, version: version, device: device) {
        case .input(let input)?: return input
        default: return nil
        }
    }

    func failure(
        _ code: ErrorCode, _ message: String, close: Bool, version: Int = ProtocolVersion.current
    ) -> HostSessionResult {
        if close {
            state = .closed
            segmentedReplies.removeAll()
            replyRequests.removeAll()
            evictedForHandoff.removeAll() // Nothing can be restored into a closed session (#723).
        }
        return HostSessionResult(
            frames: [response(.error(code: code, message: message), version: version)],
            disposition: close ? .close : .keepOpen
        )
    }
}

extension HostSession {
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
        peerCapabilities = Set(hello.capabilities.prefix(64))
        peerDeviceKind = AmbientTakeOver.deviceKind(hello.deviceKind)
        let info = HelloInfo(
            versions: VersionNegotiation.supported,
            capabilities: authorizer.capabilities + [ReplySegments.capability, ModeSnapshot.capability],
            deviceName: hostName
        )
        // WebSocketPeer sends this whole batch before receiving the next frame. Reading the snapshot is
        // synchronous and does not arm privacy, hold replies, consume parks or start a child.
        let modes = peerCapabilities.contains(ModeSnapshot.capability) ? snapshot(connectionID) : []
        return HostSessionResult(frames: [response(.hello(info), version: version)]
            + modes.map { response($0, version: version) })
    }

    func response(_ control: ControlPayload, version: Int) -> Frame {
        Frame(version: version, timestamp: now(), source: "haild", payload: .control(control))
    }
}

/// The ready-state body of `receive`, kept out of the actor body (#636 adds the voice-route step before it).
extension HostSession {
    fileprivate func receiveReady(_ frame: Frame, version: Int) async -> HostSessionResult {
        if case .control(.replyYield(let reply, let segment)) = frame.payload {
            return await receiveReplyYield(frame, reply: reply, segment: segment)
        }
        // The phone is attributed by its negotiated Hello name, never by the frame's own `source`.
        guard let admitted = await admit(frame, version: version, device: peerName) else {
            return failure(.unauthorized, "terminal action is not authorized", close: false, version: version)
        }
        // Diagnostics (#234) are stored and never answered: no error, no selection or delivery change.
        if case .control(.diagnostic(let events)) = frame.payload, let sink = authorizer.diagnostics {
            await sink.record(events, session: connectionID, device: peerName)
            return HostSessionResult(frames: [])
        }
        // A closed route kind (rightyo#164), never a port name: noted for attribution and never answered either.
        if case .control(.ambientInput(let route)) = frame.payload, let gate = authorizer.ambientAudio {
            await gate.noteInputRoute(route, connection: connectionID)
            return HostSessionResult(frames: [])
        }
        // The privacy switch (#735 S-6). A capable, unarmed owner's off also clears parks (#941),
        // answered here; an armed switch keeps the existing gate path and its notice.
        if case .control(.setPrivacy(let on)) = frame.payload, let gate = authorizer.ambientAudio {
            if !on, peerCapabilities.contains(ModeSnapshot.capability), let snapshotOff {
                switch await snapshotOff(connectionID) {
                case .refused: return HostSessionResult(frames: [])
                case .armed: break
                case .cleared:
                    let off = response(.duckMode(on: false, reason: "device"), version: version)
                    return HostSessionResult(frames: [off])
                }
            }
            await gate.setPrivacy(on, connection: connectionID)
            return HostSessionResult(frames: [])
        }
        // The host's read-only health summary (#614): always answered, from the shared cached result, on this
        // connection only, never logged. A refusal here would end an older device's connection.
        if case .control(.health) = frame.payload, let health = authorizer.health {
            return HostSessionResult(frames: [response(.healthReport(await health()), version: version)])
        }
        return await route(admitted, version: version)
    }
}
