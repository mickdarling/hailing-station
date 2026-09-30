public import Foundation
import HailProtocol

/// Unregistered by default. A deterministic in-process utility, not an observed external tmux/TUI session.
/// Composition must use the retained requestID with the owner-only reply endpoint, never choose a recipient.
public actor DiagnosticReplyBridgeAdapter: ProviderContextDelivering, ProviderReplyBindingLeasing {
    public nonisolated let kind = "diagnostic-reply"
    public nonisolated let inputShape = AdapterInputShape.singleLineContextual
    public static let targetName = "roundtrip"
    public static let targetID = "diagnostic-reply:roundtrip"
    /// Stable implementation identity lets a separate CLI grant match the running utility instance.
    /// It identifies this version of trusted utility code, not a pane, process, or authenticated terminal.
    public static let utilityBinding = "diagnostic-roundtrip-v1"
    public static let capacity = 16
    public static let concurrency = 4
    private let hostID: String
    private let publisher: @Sendable (DiagnosticBridgeReply) async throws -> Void
    private let authority = ReplyPublicationAuthority()
    private var running = true
    private var nextSequence = 1
    private var queued: [DiagnosticBridgeReply] = []
    private var active: [UUID: Task<Void, Never>] = [:]
    private var recent: [UUID: ContinuousClock.Instant] = [:]
    private var status = DiagnosticBridgeDiagnostics()

    public init(hostID: String, publisher: @escaping @Sendable (DiagnosticBridgeReply) async throws -> Void) throws {
        guard !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hostID.utf8.count <= ReplyLimits.maxIdentifierBytes,
              !hostID.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
              }) else {
            throw DiagnosticBridgeError.invalidConfiguration
        }
        self.hostID = hostID
        self.publisher = publisher
    }

    deinit {
        authority.invalidate()
        for task in active.values { task.cancel() }
    }

    public func listTargets() async throws -> [AdapterTarget] {
        [AdapterTarget(name: Self.targetName, alive: running, displayName: "Diagnostic round-trip (test utility)",
                       binding: Self.utilityBinding)]
    }

    public func acquireReplyBindingLease(_ binding: ProviderSessionBinding) async throws -> ProviderReplyBindingLease {
        try Task.checkCancellation()
        try validate(binding, target: Self.targetName, session: Self.utilityBinding)
        // Preserve all five supplied identities. The observation is fresh ingress metadata, not capture.
        return ProviderReplyBindingLease(binding: binding, permit: authority.issuePermit())
    }

    public func deliver(_ text: String, to target: String, binding: String?) async throws {
        throw DiagnosticBridgeError.contextRequired
    }

    public func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        let data = try DiagnosticBridgeEnvelope.encode(requestID: context.id, text: text)
        try acceptEnvelope(data, to: target, binding: binding, context: context)
    }

    /// No raw envelope is ever passed to a shell, model, publisher or log. Context, not text, owns request identity.
    public func acceptEnvelope(
        _ data: Data, to target: String, binding: String, context: ProviderTurnContext
    ) throws {
        try Task.checkCancellation()
        try validate(context.binding, target: target, session: binding)
        let request = try DiagnosticBridgeEnvelope.decode(data)
        guard request.requestID == context.id else { throw ProviderContractError.wrongContext }
        let now = ContinuousClock.now
        recent = recent.filter { $0.value.duration(to: now) < .seconds(120) }
        guard recent[request.requestID] == nil, active[request.requestID] == nil,
              !queued.contains(where: { $0.requestID == request.requestID }) else {
            throw DiagnosticBridgeError.duplicateRequest
        }
        guard queued.count + active.count < Self.capacity, recent.count < 64, nextSequence < Int.max else {
            throw DiagnosticBridgeError.capacityExceeded
        }
        let reply = DiagnosticBridgeReply(requestID: context.id, hostID: hostID,
                                          targetID: Self.targetID, sequence: nextSequence)
        nextSequence += 1
        recent[request.requestID] = now
        queued.append(reply)
        startWorkers()
        // Acknowledges bounded queue admission, never waits on its own dispatch commitment or publication.
    }

    private func validate(_ binding: ProviderSessionBinding, target: String, session: String) throws {
        guard running else { throw DiagnosticBridgeError.stopped }
        guard target == Self.targetName, session == Self.utilityBinding,
              binding.hostID == hostID, binding.providerID == kind, binding.targetID == Self.targetID,
              binding.sessionID == Self.utilityBinding else { throw ProviderContractError.wrongContext }
    }

    private func startWorkers() {
        while running, active.count < Self.concurrency, !queued.isEmpty {
            let reply = queued.removeFirst()
            let publisher = publisher
            active[reply.requestID] = Task { [weak self] in
                let failure: DiagnosticBridgeFailure?
                do {
                    try Task.checkCancellation()
                    try await publisher(reply)
                    failure = Task.isCancelled ? .cancelled : nil
                } catch is CancellationError { failure = .cancelled } catch { failure = .publisherFailed }
                await self?.finished(reply.requestID, failure: failure)
            }
        }
    }

    private func finished(_ request: UUID, failure: DiagnosticBridgeFailure?) {
        guard active.removeValue(forKey: request) != nil else { return }
        let failure = running ? failure : .cancelled
        switch failure {
        case nil: status.completed = increment(status.completed)
        case .cancelled, .stopped: status.cancelled = increment(status.cancelled)
        case .publisherFailed: status.failed = increment(status.failed)
        }
        if let failure { status.lastFailure = failure }
        startWorkers()
    }

    public func diagnostics() -> DiagnosticBridgeDiagnostics {
        var result = status
        result.queued = queued.count
        result.active = active.count
        return result
    }

    /// Permanent retirement: invalidate before cancelling work. A new instance never revives old permits.
    /// Callback cancellation is cooperative; ignored cancellation remains active until the callback returns.
    public func stop() {
        guard running else { return }
        authority.invalidate()
        running = false
        for _ in queued { status.cancelled = increment(status.cancelled) }
        queued.removeAll()
        for task in active.values { task.cancel() }
        status.lastFailure = .stopped
    }

    public func capture(_ target: String) async throws -> String {
        throw AdapterError.captureFailed("diagnostic utility does not support capture")
    }

    private func increment(_ value: Int) -> Int { value < Int.max ? value + 1 : value }
}
