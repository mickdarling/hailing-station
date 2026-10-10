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

    private let workspace: String

    private init(command: OwnedStdioCommand, verifiedVersion: String?, workspace: String,
                 limits: CodexStdioLimits) throws {
        guard let verifiedVersion, CodexAppServerProtocol.supportedVersions.contains(verifiedVersion) else {
            throw CodexAppServerError.incompatibleVersion
        }
        self.command = command; self.workspace = workspace; self.limits = limits; lease = try CodexOwnedLease()
    }
    /// The real-binary entry point: evidence comes from `CodexLauncher.verify`, not a caller's claim.
    static func withOwnedAdapter<Result: Sendable>(
        launch: CodexLaunchEvidence, setup: CodexLaunchSetup, limits: CodexStdioLimits = .init(),
        operation: @Sendable (CodexAppServerAdapter) async throws -> Result
    ) async throws -> Result {
        let command = try launch.appServerCommand(environment: setup.environment,
                                                  configOverrides: setup.configOverrides)
        return try await withOwnedAdapter(command: command, verifiedVersion: launch.version,
                                          workspace: setup.workspace, limits: limits, operation: operation)
    }
    /// Synthetic-test seam: `verifiedVersion` is an attestation only. Real composition uses `launch:`.
    static func withOwnedAdapter<Result: Sendable>(
        command: OwnedStdioCommand, verifiedVersion: String?, workspace: String = "/synthetic-workspace",
        limits: CodexStdioLimits = .init(), operation: @Sendable (CodexAppServerAdapter) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let adapter = try CodexAppServerAdapter(command: command, verifiedVersion: verifiedVersion,
                                                workspace: workspace, limits: limits)
        return try await withTaskCancellationHandler {
            do { let result = try await operation(adapter); await adapter.join(); return result } catch {
                await adapter.join(); throw error
            }
        } onCancel: { adapter.cancel() }
    }
    nonisolated func cancel() { lease.stop() }
    func join() async { cancel(); await lifecycle?.value }
    var isReaped: Bool { get async { await transport?.isReaped ?? true } }
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
                }
            }
        } catch { failed() }
    }
    private func failed() {
        startup?.resume(throwing: CodexAppServerError.unavailable); startup = nil
        lease.channel.finish(throwing: ProviderObservationError.unavailable); cancel()
    }
}
#endif
