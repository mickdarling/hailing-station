/// One addressable thing a host can deliver text into, as its adapter reports it (#10 item 2).
/// The registry turns `name` into the stable id `<kind>:<name>`; adapters never see ids.
public struct AdapterTarget: Sendable, Equatable, Hashable {
    /// Adapter-local name, unique within the adapter (a tmux session name, a console session id).
    public var name: String
    public var alive: Bool
    /// Friendlier label when the adapter knows one (#11 item 4); the id still uses `name`.
    public var displayName: String?
    /// Opaque identity of the thing behind `name` at listing time (tmux: session id and creation time).
    /// Policy (#41) keeps it with the authorization and passes it back on delivery, so a target that died
    /// and was replaced under the same name is refused (threat model B3). Never on the wire.
    public var binding: String?
    public init(name: String, alive: Bool = true, displayName: String? = nil, binding: String? = nil) {
        self.name = name
        self.alive = alive
        self.displayName = displayName
        self.binding = binding
    }
}
/// Targets appearing and dying, for adapters that can watch (#11 item 5).
public enum TargetEvent: Sendable, Equatable {
    case appeared(AdapterTarget), vanished(name: String)
}
/// Failures an adapter reports. The listener maps these onto `ErrorCode` (#10 item 3, #44).
public enum AdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownTarget(String)
    /// The target named exists but its binding is not the one the caller authorized.
    case rebound(String)
    case deliveryFailed(String)
    case blockedByDialog(DialogBlock)
    case captureFailed(String)
    /// The target's input already holds text that was never submitted, so nothing was delivered (#894). Only the
    /// reason is named: neither the pending text nor the refused text is carried, previewed or hashed.
    case inputPending(reason: PendingInputReason)
    public var description: String {
        switch self {
        case .unknownTarget(let target): "unknownTarget(\(String(reflecting: target)))"
        case .rebound(let target): "rebound(\(String(reflecting: target)))"
        case .deliveryFailed(let reason): "deliveryFailed(\(String(reflecting: reason)))"
        case .blockedByDialog(let block): "deliveryFailed(\(String(reflecting: block.description)))"
        case .captureFailed(let reason): "captureFailed(\(String(reflecting: reason)))"
        case .inputPending(let reason): "inputPending(reason: \(reason))"
        }
    }
}

/// Fixed dialog kinds; neither display nor speech names contain captured pane text.
public enum DialogKind: Sendable, Equatable, CaseIterable {
    case computerUsePermissions, computerUseAppApproval, toolPermission, modalFooter
    /// Fixed, bounded display titles; no pane text crosses the refusal boundary.
    public var title: String {
        switch self {
        case .computerUsePermissions: "Computer Use needs macOS permissions"
        case .computerUseAppApproval: "Computer Use wants to control these apps"
        case .toolPermission: "a tool permission dialog"
        case .modalFooter: "a dialog"
        }
    }
    /// Noun phrases for spoken notices; delivery wording is supplied by the caller.
    public var spokenName: String {
        switch self {
        case .computerUsePermissions: "Computer Use permissions dialog"
        case .computerUseAppApproval: "Computer Use app approval dialog"
        case .toolPermission: "tool permission dialog"
        case .modalFooter: "dialog"
        }
    }
}

/// Bounded dialog evidence, without captured pane text or an inference of successful delivery.
public struct DialogBlock: Sendable, Equatable, CustomStringConvertible {
    public enum Cause: Sendable, Equatable {
        /// A bounded kind from the detector's table, never copied from the pane.
        case known(DialogKind), uninspectable
    }
    public enum Effects: Sendable, Equatable { case none, pasteMayHaveExecuted, enterMayHaveExecuted }
    public let cause: Cause
    public let effects: Effects
    public init(cause: Cause, effects: Effects) {
        self.cause = cause
        self.effects = effects
    }
    public var description: String {
        switch cause {
        case .known(let kind): "target is blocked by \(kind.title)"
        case .uninspectable: "target dialog state could not be inspected"
        }
    }
}
/// Why a delivery was refused with unsent text already in the target's input (#894), as a log-safe token.
public enum PendingInputReason: String, Sendable, Equatable, CustomStringConvertible {
    /// Text at the cursor did not leave within the adapter's wait for it to clear.
    case staleInput = "stale_input"
    /// Text appeared at the cursor while the delivery was being prepared, before anything was pasted.
    case appeared
    /// An earlier delivery there never reached a known submit; refused until the adapter is restarted.
    case tainted
    public var description: String { rawValue }
}
/// Registered input shape, not a client-selected label or permission grant (#152).
public enum AdapterInputShape: Sendable, Equatable {
    /// Each sanitized line is a separate adapter delivery; preserves existing adapters.
    case lineOriented
    /// Exactly one sanitized line with explicit contextual capability; never legacy fallback.
    case singleLineContextual
}
public enum AdapterInputShapeError: Error, Sendable, Equatable {
    case contextRequired, singleLineRequired
}
/// Retained authority for one guarded dispatch, never a fresh grant.
/// Validation and operation-bearing delivery admission are separate capabilities. Admission is ordered
/// against retirement; check-only authority takes short locks only and performs no policy I/O.
/// Guarded-delivery adapters check authority immediately before each target side effect.
/// CheckedHandoffDelivering explicitly opts into a handoff-only check. Adapters supporting neither
/// guarded delivery contract must refuse guarded delivery.
public struct DeliveryAuthority: Sendable {
    private let check: @Sendable () throws -> Void
    private let admission: DeliveryAdmission?
    init(check: @escaping @Sendable () throws -> Void) { self.check = check; admission = nil }
    init(admission: DeliveryAdmission) {
        check = { try admission.validate() }
        self.admission = admission
    }
    /// Operation-bearing authority validates without committing cancellation or an attempt.
    /// Check-only authority preserves its existing handoff check.
    public func requireCurrent() throws { try check() }
    public var supportsAdmission: Bool { admission != nil }
    /// Operation-bearing delivery admission is ordered against retirement. The operation is synchronous
    /// and nonescaping; it must not suspend, wait for completion, retire or reacquire any authority gate.
    /// Check-only authority, including authority used by CheckedHandoffDelivering, fails closed here.
    /// An error does not prove the operation did not run. Callers rely on the attempt/cancellation
    /// record and never retry on error.
    public func admit<Value>(_ operation: () throws -> Value) throws -> Value {
        guard let admission else { throw DeliveryAdmissionError.unsupported }
        return try admission.admit(operation)
    }
}
/// The adapter interface (#10 item 2). Implementations are actors or otherwise `Sendable`; every call is
/// async because adapters shell out, poll, or talk to another process. `events` is optional: the default
/// is an already-finished stream, so the registry can treat every adapter alike.
public protocol Adapter: Sendable {
    /// Lowercase `[a-z0-9-]` label used as the id prefix: `tmux`, `console`, `http`. Never contains `:`.
    var kind: String { get }
    var inputShape: AdapterInputShape { get }
    func listTargets() async throws -> [AdapterTarget]
    /// Deliver `text` literally to the target named `target` (adapter-local name, not the id). With a
    /// `binding` from an earlier listing, the adapter delivers only if the target still has that binding.
    func deliver(_ text: String, to target: String, binding: String?) async throws
    /// The default refuses unless the adapter explicitly opts into CheckedHandoffDelivering.
    func deliver(_ text: String, to target: String, binding: String?, authority: DeliveryAuthority) async throws
    /// Send the target a literal Escape key. Adapters that cannot represent it fail closed.
    func escape(_ target: String, binding: String?) async throws
    /// The visible tail of the target's output, trimmed.
    func capture(_ target: String) async throws -> String
    var events: AsyncStream<TargetEvent> { get }
}
/// Explicit opt-in to checking retained authority once, immediately before handing off to unguarded delivery.
/// This preserves loop-boundary semantics; retirement after handoff can still allow in-flight side effects.
/// Applies only to Adapter's default authority overload; contextual delivery has its own separate contract.
public protocol CheckedHandoffDelivering: Adapter {}
extension Adapter {
    public var inputShape: AdapterInputShape { .lineOriented }
    public var events: AsyncStream<TargetEvent> { AsyncStream { $0.finish() } }
    /// Unbound delivery, for callers that have no listing in hand. Policy (#41) always passes a binding.
    public func deliver(_ text: String, to target: String) async throws {
        try await deliver(text, to: target, binding: nil)
    }
    public func deliver(
        _ text: String, to target: String, binding: String?, authority: DeliveryAuthority
    ) async throws {
        guard self is any CheckedHandoffDelivering else {
            throw AdapterError.deliveryFailed("guarded_delivery_unsupported")
        }
        try authority.requireCurrent()
        try await deliver(text, to: target, binding: binding)
    }
    public func escape(_ target: String, binding: String?) async throws {
        throw AdapterError.deliveryFailed("adapter does not support Escape")
    }
}
extension DiagnosticReplyBridgeAdapter {
    // #1028 part 4 targets tmux paste/Enter; this utility keeps its contextual queue handoff check.
    public func deliver(
        _ text: String, to target: String, binding: String, context: ProviderTurnContext, authority: DeliveryAuthority
    ) async throws {
        try authority.requireCurrent()
        try await deliver(text, to: target, binding: binding, context: context)
    }
}
#if os(macOS)
extension CodexAppServerAdapter {
    // #1028 part 4 targets tmux paste/Enter; this provider keeps its contextual handoff check.
    func deliver(
        _ text: String, to target: String, binding: String, context: ProviderTurnContext, authority: DeliveryAuthority
    ) async throws {
        try authority.requireCurrent()
        try await deliver(text, to: target, binding: binding, context: context)
    }
}
#endif
