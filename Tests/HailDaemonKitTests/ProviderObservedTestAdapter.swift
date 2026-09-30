import Foundation
@testable import HailDaemonKit

actor ObservedAdapter: ProviderContextDelivering, ProviderSessionObserving {
    nonisolated let kind = "observed"
    nonisolated let observationCapabilities: Set<ProviderObservationCapability> = [
        .userVisibleText, .explicitAcceptance, .explicitCompletion
    ]
    nonisolated let cancellations = ObservedCounter()
    nonisolated let terminations = ObservedCounter()
    nonisolated let listings = ObservedCounter()
    nonisolated let startup = ObservedGate()
    nonisolated let dispatch = ObservedGate()
    nonisolated let listing = ObservedGate()
    private var heldListings: Set<Int> = []
    var holdStartup = false
    var holdDispatch = false
    var failureAfter: Int?
    var emitBeforeFailure = false
    var emission: [ProviderEventKind] = [.accepted, .text("invented provider output", isFinal: true,
                                                      visibility: .userVisible), .finished]
    private(set) var delivered: [ProviderTurnContext] = []
    private(set) var observationCount = 0
    private var sessionID = "opaque-observed"
    private var channel: ProviderEventChannel?
    private var observed: ProviderSessionBinding?
    private var sequence = 0
    private var lastEvent: ProviderSessionEvent?
    func listTargets() async throws -> [AdapterTarget] {
        listings.increment()
        if heldListings.remove(listings.count) != nil { await listing.pause() }
        return [AdapterTarget(name: "session", binding: sessionID)]
    }
    func replace() { sessionID = "replaced" }
    func configure(holdStartup: Bool = false, holdDispatch: Bool = false, failureAfter: Int? = nil) {
        self.holdStartup = holdStartup; self.holdDispatch = holdDispatch; self.failureAfter = failureAfter
    }
    func setEmission(_ kinds: [ProviderEventKind]) { emission = kinds }
    func holdListing(_ number: Int) { heldListings.insert(number) }
    func replayLast() { if let lastEvent { channel?.yield(lastEvent) } }
    func setEmitBeforeFailure() { emitBeforeFailure = true }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        throw ProviderObservationError.unavailable
    }
    func observe(_ binding: ProviderSessionBinding) async throws -> ProviderObservation {
        guard binding.sessionID == sessionID else { throw AdapterError.rebound("session") }
        observationCount += 1; observed = binding; sequence = 0
        let channel = try ProviderEventChannel(capacity: 64) { self.terminations.increment() }
        self.channel = channel
        if holdStartup { await startup.pause() }
        return ProviderObservation(events: channel.stream) {
            self.cancellations.increment(); channel.finish(throwing: ProviderObservationError.interrupted)
        }
    }
    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        guard binding == sessionID else { throw AdapterError.rebound(target) }
        if let failureAfter, delivered.count >= failureAfter {
            if emitBeforeFailure { try produce(context) }
            throw ProviderCoordinatorSyntheticError.arbitraryFailure
        }
        delivered.append(context)
        // Independently scheduled adapter work emits from the exact context received through Registry.
        try await Task.detached { try await self.produce(context) }.value
        if holdDispatch { await dispatch.pause() }
    }
    private func produce(_ context: ProviderTurnContext) throws {
        for kind in emission { try emit(kind, turn: context) }
    }
    func emit(_ kind: ProviderEventKind, turn: ProviderTurnContext? = nil, sequenceOverride: Int? = nil) throws {
        guard let observed else { throw ProviderObservationError.unavailable }
        let event = try ProviderSessionEvent(binding: observed, sequence: sequenceOverride ?? sequence,
                                             turn: turn, kind: kind)
        sequence += 1
        lastEvent = event
        channel?.yield(event)
    }
    func finish(_ error: (any Error)? = nil) { channel?.finish(throwing: error) }
}
