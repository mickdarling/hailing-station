// Lifecycle helpers share private actor state; keeping cleanup and retention transitions together is deliberate.
// swiftlint:disable file_length
public import Foundation

public enum ProviderObservationLoss: Error, Sendable, Equatable {
    case authorizationLost, streamEnded, streamFailed, bufferOverflow, orderingGap, capacityExceeded
}
public enum ProviderObservedSessionError: Error, Sendable, Equatable { case legacyInputUnsupported, captureDenied }
public enum ProviderObservedSessionStatus: Sendable, Equatable {
    case active, stopped, lost(ProviderObservationLoss)
}
public struct ProviderObservedEvent: Sendable, Equatable {
    public let event: ProviderSessionEvent
    public let correlation: ProviderEventCorrelation
}
public struct ProviderSessionClock: Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    public var sleep: @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }
    public init() {}
}

/// Scoped host-local capture, not disclosure authorization, network publication or a real-provider implementation.
public actor ProviderObservedSession {
    public struct Configuration: Sendable {
        public var hostID = "local-host"
        public var pollInterval: Duration = .milliseconds(250)
        public var maxQueuedEvents = 64
        public var maxQueuedTextBytes = 262_144
        public var input: ProviderInputCoordinator.Configuration = .init(deliveryMode: .contextual)
        public var clock = ProviderSessionClock()
        public init() {}
    }
    public let binding: ProviderSessionBinding
    public let connectionID: UUID
    public private(set) var status: ProviderObservedSessionStatus = .active
    private let host: HailHost
    private let coordinator: ProviderInputCoordinator
    private let config: Configuration
    private let cleanup: ObservationCleanup
    private var pending: [ProviderSessionEvent] = []
    private var ready: [ProviderObservedEvent] = []
    private var bytes = 0
    private var working = false
    private var ingesting = 0
    private var consuming = false
    private var closed = false
    private var waiter: CheckedContinuation<ProviderObservedEvent?, any Error>?
    private var input: Task<ProviderInputOutcome, any Error>?

    init(
        host: HailHost, binding: ProviderSessionBinding, config: Configuration, cleanup: ObservationCleanup
    ) throws {
        self.host = host; self.binding = binding; self.config = config; self.cleanup = cleanup
        connectionID = UUID()
        coordinator = try ProviderInputCoordinator(host: host, binding: binding, connectionID: connectionID,
            configuration: .init(timeout: config.input.timeout, maxTurns: config.input.maxTurns,
                                 maxEvents: config.input.maxEvents, deliveryMode: .contextual), now: config.clock.now)
    }

    public func submit(_ text: String, utteranceID: UUID, from device: String = "keyboard",
                       confirmedHash: String? = nil) async throws -> ProviderInputOutcome {
        try await withTaskCancellationHandler {
            try await submitAuthorized(text, utteranceID: utteranceID, from: device, confirmedHash: confirmedHash)
        } onCancel: { self.cleanup.cancel(stopping: true); Task { await self.stop() } }
    }
    private func submitAuthorized(_ text: String, utteranceID: UUID, from device: String,
                                  confirmedHash: String?) async throws -> ProviderInputOutcome {
        guard status == .active else { throw ProviderObservationError.interrupted }
        guard !working else { throw ProviderInputCoordinatorError.dispatchInProgress }
        working = true
        do {
            guard await authorize() else {
                try Task.checkCancellation()
                throw ProviderObservedSessionError.captureDenied
            }
            try Task.checkCancellation()
            guard status == .active, !closed else { throw ProviderObservationError.interrupted }
            let input = Task { try await coordinator.submit(text, utteranceID: utteranceID, from: device,
                                                            confirmedHash: confirmedHash) }
            self.input = input
            let outcome = try await input.value
            self.input = nil
            working = false
            await drain()
            return outcome // A completed write remains sent even if stop occurred while awaiting it.
        } catch {
            input = nil
            working = false
            if error as? ProviderContractError == .capacityExceeded { close(.lost(.capacityExceeded)) }
            await drain()
            throw error
        }
    }

    /// One scoped consumer. Returning from the scope, including an early loop break, stops capture.
    public func next() async throws -> ProviderObservedEvent? {
        try await withTaskCancellationHandler { try await nextAuthorized() } onCancel: {
            self.cleanup.cancel(stopping: true); Task { await self.stop() }
        }
    }
    private func nextAuthorized() async throws -> ProviderObservedEvent? {
        if Task.isCancelled { close(.stopped); throw CancellationError() }
        guard !consuming else { throw ProviderInputCoordinatorError.dispatchInProgress }
        consuming = true
        defer { consuming = false }
        if mayDrain { _ = await authorize() }
        try Task.checkCancellation()
        if !ready.isEmpty {
            let result = ready.removeFirst(); bytes -= textBytes(result.event)
            return result
        }
        if case .lost(let reason) = status, pending.isEmpty, ingesting == 0 { throw reason }
        guard mayDrain else { return nil }
        let result: ProviderObservedEvent? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                if Task.isCancelled { $0.resume(throwing: CancellationError()) } else { waiter = $0 }
            }
        } onCancel: { Task { await self.stop() } }
        try Task.checkCancellation()
        return result
    }

    public func stop() { close(.stopped) }
    public func state(for turnID: UUID) async -> ProviderTurnState? {
        await coordinator.expireDueTurns()
        return await coordinator.state(for: turnID)
    }
}
extension ProviderObservedSession {
    private var mayDrain: Bool { !closed && status != .stopped && status != .lost(.authorizationLost) }
    private func close(_ terminal: ProviderObservedSessionStatus) {
        let purge = terminal == .stopped || terminal == .lost(.authorizationLost)
        guard status == .active || purge else { return }
        if status == .active || terminal == .lost(.authorizationLost) { status = terminal }
        cleanup.cancel(stopping: purge) // Before joining any noncooperative input or monitoring work.
        if purge { closed = true; pending.removeAll(); ready.removeAll(); bytes = 0; input?.cancel() }
        finishWaiter() // EOF's valid early prefix awaits dispatch registration.
    }
    private func finishWaiter() {
        guard status != .active, pending.isEmpty, ingesting == 0 else { return }
        if case .lost(let reason) = status { waiter?.resume(throwing: reason) } else {
            waiter?.resume(returning: nil)
        }
        waiter = nil
    }
    private func authorize() async -> Bool {
        do { try await host.validateObservation(binding); return mayDrain } catch is CancellationError {
            close(.stopped); return false
        } catch {
            close(.lost(.authorizationLost)); return false
        }
    }
    private func textBytes(_ event: ProviderSessionEvent) -> Int {
        if case .text(let text, _, _) = event.kind { return text.utf8.count }
        return 0
    }
    private func discardPending() {
        pending.forEach { bytes -= textBytes($0) }; pending.removeAll()
    }
    private func receive(_ event: ProviderSessionEvent) async {
        guard status == .active, await authorize() else { return }
        guard event.binding == binding else { close(.lost(.streamFailed)); return }
        let size = textBytes(event)
        guard pending.count + ready.count + ingesting < config.maxQueuedEvents,
              size <= config.maxQueuedTextBytes - bytes else { close(.lost(.bufferOverflow)); return }
        pending.append(event); bytes += size
        await drain()
    }
    private func drain() async {
        guard !working, mayDrain else { return }
        working = true
        defer { working = false; ingesting = 0; finishWaiter() }
        while !pending.isEmpty, mayDrain {
            guard await authorize() else { return }
            let event = pending.removeFirst()
            ingesting = 1
            let result: ProviderEventCorrelation
            do { result = try await coordinator.ingest(event) } catch {
                ingesting = 0; bytes -= textBytes(event); discardPending(); close(.lost(.streamFailed)); return
            }
            guard await authorize() else { return } // Ingestion's actor hop cannot carry a cached capture grant.
            ingesting = 0
            if result == .rejected(.capacityExceeded) || result == .rejected(.sequenceGap) {
                bytes -= textBytes(event)
                discardPending() // An invalid ordering/capacity suffix cannot remain parked behind terminal loss.
                close(.lost(result == .rejected(.sequenceGap) ? .orderingGap : .capacityExceeded)); return
            }
            let record = ProviderObservedEvent(event: event, correlation: result)
            if let waiter { self.waiter = nil; bytes -= textBytes(event); waiter.resume(returning: record) } else {
                ready.append(record)
            }
        }
    }
    private func read(_ lease: ProviderObservation) async {
        do {
            for try await event in lease.events { await receive(event); if status != .active { return } }
            close(Task.isCancelled ? .stopped : .lost(.streamEnded))
        } catch {
            let reason: ProviderObservationLoss = error as? ProviderObservationError == .bufferOverflow
                ? .bufferOverflow : .streamFailed
            close(Task.isCancelled || cleanup.isStopping ? .stopped : .lost(reason))
        }
    }
    private func monitor() async {
        do {
            while status == .active {
                try await config.clock.sleep(config.pollInterval)
                guard await authorize() else { return }
                await coordinator.expireDueTurns()
            }
        } catch { close(Task.isCancelled ? .stopped : .lost(.streamFailed)) }
    }
    func run<Result: Sendable>(
        _ lease: ProviderObservation, operation: @escaping @Sendable (ProviderObservedSession) async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.read(lease) }
            group.addTask { await self.monitor() }
            defer { cleanup.cancel(); group.cancelAll() }
            do {
                let result = try await operation(self)
                close(.stopped)
                if let input { _ = try await input.value }
                return result
            } catch {
                close(.stopped)
                // Join cleanup without replacing the scope's original error.
                if let input { _ = try? await input.value }
                throw error
            }
        }
    }
}
