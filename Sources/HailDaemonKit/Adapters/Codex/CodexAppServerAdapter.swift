#if os(macOS)
import Foundation
import Synchronization

/// One immutable generation. Stop is synchronous even while an actor is suspended in provider I/O.
private final class CodexOwnedLease: Sendable {
    private let state = Mutex<(stopped: Bool, transport: CodexStdioTransport?)>((false, nil))
    let channel: ProviderEventChannel
    init() throws { channel = try ProviderEventChannel(capacity: 64) }
    var stopped: Bool { state.withLock { $0.stopped } }
    func start(_ command: OwnedStdioCommand, limits: CodexStdioLimits) throws -> CodexStdioTransport {
        try state.withLock { state in
            guard !state.stopped, state.transport == nil else { throw CodexAppServerError.unavailable }
            let transport = try CodexStdioTransport(command: command, limits: limits)
            state.transport = transport
            return transport
        }
    }
    func stop() {
        let transport = state.withLock { state -> CodexStdioTransport? in
            state.stopped = true; return state.transport
        }
        transport?.cancel(); channel.finish(throwing: ProviderObservationError.interrupted)
    }
    func yield(_ events: [ProviderSessionEvent]) {
        // The lock linearizes yield with invalidation, not merely with the actor's next await.
        state.withLock { state in
            guard !state.stopped else { return }
            for event in events where !channel.yield(event) { state.stopped = true; state.transport?.cancel(); break }
        }
    }
}

/// Experimental and internal. No default command, live registration, existing thread attachment or auth export.
actor CodexAppServerAdapter: ProviderContextDelivering, ProviderSessionObserving {
    nonisolated let kind = "codex-owned"
    nonisolated let inputShape = AdapterInputShape.singleLineContextual
    nonisolated let observationCapabilities: Set<ProviderObservationCapability> = [
        .userVisibleText, .explicitAcceptance, .explicitCompletion
    ]
    nonisolated let sessionID = UUID().uuidString
    private nonisolated let lease: CodexOwnedLease
    private let command: OwnedStdioCommand
    private let limits: CodexStdioLimits
    private var observed: ProviderSessionBinding?
    private var events: CodexAppServerEvents?
    private var lifecycle: Task<Void, Never>?
    private var startup: CheckedContinuation<ProviderObservation, any Error>?
    private var transport: CodexStdioTransport?
    private var terminalWaiter: CodexTerminalWaiter?
    private var interrupting = false // Reserved before the request await: one interrupt at a time.
    var graceSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) } // Test seam, #727
    private let workspace: String
    /// Real launches re-run every workspace check at the actual child launch; nil only for the synthetic seam.
    private let setup: CodexLaunchSetup?

    private init(command: OwnedStdioCommand, verifiedVersion: String?, workspace: String,
                 setup: CodexLaunchSetup? = nil, limits: CodexStdioLimits) throws {
        guard let verifiedVersion, CodexAppServerProtocol.supportedVersions.contains(verifiedVersion) else {
            throw CodexAppServerError.incompatibleVersion
        }
        self.command = command; self.workspace = workspace; self.setup = setup; self.limits = limits
        lease = try CodexOwnedLease()
    }
    /// The real-binary entry point: evidence comes from `CodexLauncher.verify`, not a caller's claim.
    static func withOwnedAdapter<Result: Sendable>(
        launch: CodexLaunchEvidence, setup: CodexLaunchSetup, limits: CodexStdioLimits = .init(),
        operation: @Sendable (CodexAppServerAdapter) async throws -> Result
    ) async throws -> Result {
        let setup = try setup.revalidated()
        let command = try launch.appServerCommand(environment: setup.environment,
                                                  configOverrides: setup.configOverrides)
        try Task.checkCancellation()
        let adapter = try CodexAppServerAdapter(command: command, verifiedVersion: launch.version,
                                                workspace: setup.workspace, setup: setup, limits: limits)
        return try await scoped(adapter, operation: operation)
    }
    /// Synthetic-test seam: `verifiedVersion` is an attestation only. Real composition uses `launch:`.
    static func withOwnedAdapter<Result: Sendable>(
        command: OwnedStdioCommand, verifiedVersion: String?, workspace: String = "/synthetic-workspace",
        limits: CodexStdioLimits = .init(), operation: @Sendable (CodexAppServerAdapter) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let adapter = try CodexAppServerAdapter(command: command, verifiedVersion: verifiedVersion,
                                                workspace: workspace, limits: limits)
        return try await scoped(adapter, operation: operation)
    }
    private static func scoped<Result: Sendable>(
        _ adapter: CodexAppServerAdapter, operation: @Sendable (CodexAppServerAdapter) async throws -> Result
    ) async throws -> Result {
        try await withTaskCancellationHandler {
            do { let result = try await operation(adapter); await adapter.join(); return result } catch {
                await adapter.join(); throw error
            }
        } onCancel: { adapter.cancel() }
    }
    nonisolated func cancel() { lease.stop() }
    func join() async { cancel(); await lifecycle?.value }
    var isReaped: Bool { get async { await transport?.isReaped ?? true } }
    /// Whether a child transport was ever started for this adapter (reaped or not).
    var launchedChild: Bool { transport != nil }
    var bufferedEarlyRecords: Int { events?.bufferedEarlyRecords ?? 0 }
    func listTargets() async throws -> [AdapterTarget] {
        lease.stopped ? [] : [AdapterTarget(name: "owned", binding: sessionID)]
    }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        throw AdapterInputShapeError.contextRequired
    }
    func capture(_ target: String) async throws -> String { throw ProviderObservationError.unavailable }
    func observe(_ binding: ProviderSessionBinding) async throws -> ProviderObservation {
        guard !lease.stopped, observed == nil, binding.providerID == kind,
              binding.targetID == "\(kind):owned", binding.sessionID == sessionID else {
            throw CodexAppServerError.unavailable
        }
        observed = binding
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                startup = ready
                lifecycle = Task {
                    var launched: CodexStdioTransport?
                    do {
                        _ = try setup?.revalidated() // At the actual launch, not only on scope entry.
                        let transport = try lease.start(command, limits: limits); launched = transport
                        try await withTaskCancellationHandler {
                            try await self.run(transport, binding: binding)
                        } onCancel: { self.cancel() }
                    } catch { failed() }
                    await launched?.join()
                }
            }
        } onCancel: { self.cancel() }
    }
    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        guard !lease.stopped, target == "owned", binding == sessionID,
              context.binding == observed, let transport, let threadID = events?.threadID else {
            throw CodexAppServerError.unavailable
        }
        let params = try CodexAppServerProtocol.turnInput(text, threadID: threadID)
        try events?.begin(context)
        let id: String
        do {
            id = try CodexAppServerProtocol.turnID(try await transport.request(.turnStart, params: params))
        } catch { failed(); throw error as? CodexAppServerError ?? CodexAppServerError.unavailable }
        // The validated receipt commits sent evidence; observation failure cannot invite replay.
        guard !lease.stopped else { return }
        do { lease.yield(try events?.bind(id) ?? []) } catch { failed() }
    }
}
extension CodexAppServerAdapter {
    private func run(_ transport: CodexStdioTransport, binding: ProviderSessionBinding) async throws {
        self.transport = transport
        let threadID = try await CodexAppServerProtocol.start(transport, workspace: workspace)
        guard !lease.stopped else { throw CodexAppServerError.unavailable }
        events = CodexAppServerEvents(binding: binding, threadID: threadID)
        startup?.resume(returning: ProviderObservation(events: lease.channel.stream) { self.cancel() }); startup = nil
        do {
            while !lease.stopped {
                if let record = try CodexAppServerRecord(try await transport.nextNotification()) {
                    lease.yield(try events?.receive(record) ?? [])
                    if let waiter = terminalWaiter, let kind = events?.terminal(for: waiter.turn) { resolve(kind) }
                }
            }
            resolve(nil) // A normal stop never leaves an interrupt waiting out its grace.
        } catch { failed() }
    }
    /// Exact-ID provider interruption of the active turn. True only when the provider accepted the request and
    /// the matching explicit `interrupted` terminal arrived within `grace`. Never kills the child; stopping the
    /// lease remains separate. A request timeout ends the lease; caller cancellation never does (the request is
    /// shielded) and returns false. `grace` is bounded to (0, 10 s].
    func interruptActiveTurn(grace: Duration = .seconds(2)) async -> Bool {
        guard grace > .zero, grace <= .seconds(10), !interrupting, !lease.stopped, let transport, let events,
              let turn = events.activeTurnID else { return false }
        interrupting = true; defer { interrupting = false }
        // Unstructured: caller cancellation must not cancel the transport request (and with it the whole lease).
        let request = Task { [thread = events.threadID] in
            try await CodexAppServerProtocol.interrupt(transport, threadID: thread, turnID: turn) }
        guard case .success = await request.result, !Task.isCancelled else { return false }
        if let kind = self.events?.terminal(for: turn) { return kind == .interrupted }
        guard !lease.stopped else { return false }
        let token = UUID(); let interrupted = await withTaskCancellationHandler {
            await withCheckedContinuation { done in
                // A cancelled sleep means the waiter was already resolved; only this exact waiter can expire.
                let timer = Task { [sleep = graceSleep] in if (try? await sleep(grace)) != nil { self.expire(token) } }
                terminalWaiter = CodexTerminalWaiter(turn: turn, token: token, done: done, timer: timer)
            }
        } onCancel: { Task { await self.expire(token) } }
        return interrupted && !Task.isCancelled // Cancellation wins even if the terminal raced it.
    }
    private func expire(_ token: UUID) { if terminalWaiter?.token == token { resolve(nil) } }
    private func resolve(_ kind: ProviderEventKind?) {
        guard let waiter = terminalWaiter else { return }
        terminalWaiter = nil; waiter.timer.cancel(); waiter.done.resume(returning: kind == .interrupted)
    }
    private func failed() {
        resolve(nil)
        startup?.resume(throwing: CodexAppServerError.unavailable); startup = nil
        lease.channel.finish(throwing: ProviderObservationError.unavailable); cancel()
    }
}
#endif
