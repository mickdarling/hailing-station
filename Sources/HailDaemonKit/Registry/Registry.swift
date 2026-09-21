public import HailProtocol

/// Why the registry refused an adapter or an id (#10 item 2).
public enum RegistryError: Error, Equatable, Sendable {
    /// `kind` is empty or has a character outside `[a-z0-9-]`; ids would be ambiguous or unparsable.
    case invalidKind(String)
    case duplicateKind(String)
    /// The id is not `<kind>:<name>` with a registered kind and a non-empty name.
    case unknownTarget(String)
}

/// Owns the adapters and merges their targets under stable ids `<kind>:<name>` (#10 item 2).
/// An adapter that fails to list, or lists two targets with one name, is reported in `lastFailures` for
/// that refresh, so one broken adapter never hides the others and a duplicate id never reaches a terminal
/// or an id-keyed allow list (#41). Policy (deny-by-default, tiers) sits above this in #41; `deliver` and
/// `capture` are `package` until #41 supplies the checked entry point.
public actor Registry {
    private static let kindAlphabet = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    private var adapters: [String: any Adapter] = [:]
    /// Kind to reason, for kinds that failed on the most recent `targets()` call. Concurrent `targets()`
    /// calls each overwrite it; the last writer wins.
    public private(set) var lastFailures: [String: String] = [:]

    public init() {}

    public var kinds: [String] { adapters.keys.sorted() }

    public func register(_ adapter: any Adapter) throws {
        let kind = adapter.kind
        guard !kind.isEmpty, kind.allSatisfy(Self.kindAlphabet.contains) else {
            throw RegistryError.invalidKind(kind)
        }
        guard adapters[kind] == nil else { throw RegistryError.duplicateKind(kind) }
        adapters[kind] = adapter
    }

    /// A target as listed, with the binding that listing reported. Bindings never travel on the wire
    /// (`TargetInfo` has none); policy (#41) keeps the one it authorised and passes it to `deliver`.
    public struct Listed: Sendable, Equatable {
        public var info: TargetInfo
        public var binding: String?
    }

    /// Every adapter's targets, ids `<kind>:<name>`, sorted by id so two calls with the same state
    /// produce the same list. Throws only `CancellationError`, leaving `lastFailures` untouched.
    public func targets() async throws -> [TargetInfo] {
        try await listing().map(\.info)
    }

    /// The listing with each target's binding, from one refresh: a caller that needs both takes them
    /// together, since a refresh is reentrant and a second one may complete in between two calls.
    public func listing() async throws -> [Listed] {
        var merged: [Listed] = []
        var failures: [String: String] = [:]
        var seen = Set<String>()
        for kind in kinds {
            guard let adapter = adapters[kind] else { continue }
            do {
                for target in try await adapter.listTargets() {
                    let id = Self.id(kind: kind, name: target.name)
                    guard !target.name.isEmpty, seen.insert(id).inserted else {
                        failures[kind] = target.name.isEmpty
                            ? "empty target name" : "duplicate target name \(target.name)"
                        continue
                    }
                    let info = TargetInfo(
                        id: id, kind: kind, name: target.displayName ?? target.name, alive: target.alive
                    )
                    merged.append(Listed(info: info, binding: target.binding))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[kind] = "\(error)"
            }
        }
        lastFailures = failures
        return merged.sorted { $0.info.id < $1.info.id }
    }

    /// `binding` is the value from the listing that authorised this delivery (#41); the adapter refuses a
    /// target whose binding changed since.
    package func deliver(_ text: String, to id: String, binding: String?) async throws {
        let (adapter, name) = try resolve(id)
        try await adapter.deliver(text, to: name, binding: binding)
    }

    package func escape(_ id: String, binding: String?) async throws {
        let (adapter, name) = try resolve(id)
        try await adapter.escape(name, binding: binding)
    }

    package func capture(_ id: String) async throws -> String {
        let (adapter, name) = try resolve(id)
        return try await adapter.capture(name)
    }

    public static func id(kind: String, name: String) -> String { "\(kind):\(name)" }

    /// Splits at the first `:` only, so a name may itself contain colons.
    func resolve(_ id: String) throws -> (adapter: any Adapter, name: String) {
        guard let colon = id.firstIndex(of: ":") else { throw RegistryError.unknownTarget(id) }
        let kind = String(id[..<colon])
        let name = String(id[id.index(after: colon)...])
        guard !name.isEmpty, let adapter = adapters[kind] else { throw RegistryError.unknownTarget(id) }
        return (adapter, name)
    }
}
