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
    case appeared(AdapterTarget)
    case vanished(name: String)
}

/// Failures an adapter reports. The listener maps these onto `ErrorCode` (#10 item 3, #44).
public enum AdapterError: Error, Equatable, Sendable {
    case unknownTarget(String)
    /// The target named exists but its binding is not the one the caller authorized.
    case rebound(String)
    case deliveryFailed(String)
    case captureFailed(String)
}

/// The adapter interface (#10 item 2). Implementations are actors or otherwise `Sendable`; every call is
/// async because adapters shell out, poll, or talk to another process. `events` is optional: the default
/// is an already-finished stream, so the registry can treat every adapter alike.
public protocol Adapter: Sendable {
    /// Lowercase `[a-z0-9-]` label used as the id prefix: `tmux`, `console`, `http`. Never contains `:`.
    var kind: String { get }
    func listTargets() async throws -> [AdapterTarget]
    /// Deliver `text` literally to the target named `target` (adapter-local name, not the id). With a
    /// `binding` from an earlier listing, the adapter delivers only if the target still has that binding.
    func deliver(_ text: String, to target: String, binding: String?) async throws
    /// The visible tail of the target's output, trimmed.
    func capture(_ target: String) async throws -> String
    var events: AsyncStream<TargetEvent> { get }
}

extension Adapter {
    public var events: AsyncStream<TargetEvent> {
        AsyncStream { $0.finish() }
    }

    /// Unbound delivery, for callers that have no listing in hand. Policy (#41) always passes a binding.
    public func deliver(_ text: String, to target: String) async throws {
        try await deliver(text, to: target, binding: nil)
    }
}
