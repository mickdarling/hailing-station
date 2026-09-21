@testable import HailDaemonKit

/// Records deliveries and captures; lists whatever it is given, or throws when told to (#10 tests).
actor FakeAdapter: Adapter {
    nonisolated let kind: String
    private(set) var targetsToList: [AdapterTarget]
    private(set) var listError: (any Error)?
    struct Delivery: Equatable {
        var target: String
        var text: String
        var binding: String?
    }

    private(set) var deliveries: [Delivery] = []
    private(set) var captures: [String] = []
    private(set) var escapes: [String] = []
    private let deliverError: (any Error)?
    /// After this many successful deliveries, every further one throws `AdapterError.rebound`.
    private let failAfter: Int?

    init(
        kind: String, targets: [AdapterTarget] = [], listError: (any Error)? = nil,
        deliverError: (any Error)? = nil, failAfter: Int? = nil
    ) {
        self.kind = kind
        self.targetsToList = targets
        self.listError = listError
        self.deliverError = deliverError
        self.failAfter = failAfter
    }

    func listTargets() async throws -> [AdapterTarget] {
        if let listError { throw listError }
        return targetsToList
    }

    /// What later listings report: a target that died and came back under the same name (#41 rebound).
    func setTargets(_ targets: [AdapterTarget]) {
        targetsToList = targets
    }

    func deliver(_ text: String, to target: String, binding: String?) async throws {
        guard targetsToList.contains(where: { $0.name == target }) else { throw AdapterError.unknownTarget(target) }
        if let deliverError { throw deliverError }
        if let failAfter, deliveries.count >= failAfter { throw AdapterError.rebound(target) }
        deliveries.append(Delivery(target: target, text: text, binding: binding))
    }

    func capture(_ target: String) async throws -> String {
        captures.append(target)
        return "tail of \(target)"
    }

    func escape(_ target: String, binding: String?) async throws {
        guard let listed = targetsToList.first(where: { $0.name == target }) else {
            throw AdapterError.unknownTarget(target)
        }
        if let binding, listed.binding != binding { throw AdapterError.rebound(target) }
        escapes.append(target)
    }
}

/// Overrides `events` to prove the stream reaches callers through `any Adapter` (#10 item 2).
actor EventfulFakeAdapter: Adapter {
    nonisolated let kind = "watched"
    nonisolated let events: AsyncStream<TargetEvent>

    init(_ sequence: [TargetEvent]) {
        events = AsyncStream { continuation in
            for event in sequence { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listTargets() async throws -> [AdapterTarget] { [] }
    func deliver(_ text: String, to target: String, binding: String?) async throws {}
    func capture(_ target: String) async throws -> String { "" }
}

/// Delivers only when released, so a test can act while the host is suspended inside `deliver` (#41
/// re-evaluation before every line).
actor GatedFakeAdapter: Adapter {
    nonisolated let kind = "tmux"
    private let target: AdapterTarget
    private(set) var deliveries: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(_ target: AdapterTarget) {
        self.target = target
    }

    func listTargets() async throws -> [AdapterTarget] { [target] }

    func deliver(_ text: String, to name: String, binding: String?) async throws {
        arrivals.popLast()?.resume()
        await withCheckedContinuation { waiting.append($0) }
        deliveries.append(text)
    }

    func capture(_ target: String) async throws -> String { "" }

    /// Resolves once the next `deliver` has started and is parked.
    func nextArrival() async {
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        waiting.popLast()?.resume()
    }
}

/// Parks one requested listing so a test can change policy during `Registry.listing()` reentrancy.
actor GatedListingFakeAdapter: Adapter {
    nonisolated let kind = "tmux"
    private let target: AdapterTarget
    private(set) var deliveries: [String] = []
    private var gateNext = false
    private var blocked = false
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(_ target: AdapterTarget) {
        self.target = target
    }

    func listTargets() async throws -> [AdapterTarget] {
        if gateNext {
            gateNext = false
            blocked = true
            arrivals.forEach { $0.resume() }
            arrivals.removeAll()
            await withCheckedContinuation { releases.append($0) }
            blocked = false
        }
        return [target]
    }

    func deliver(_ text: String, to target: String, binding: String?) async throws {
        deliveries.append(text)
    }

    func capture(_ target: String) async throws -> String { "" }

    func gateNextListing() {
        gateNext = true
    }

    func nextListingArrival() async {
        if blocked { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func releaseListing() {
        releases.popLast()?.resume()
    }
}
