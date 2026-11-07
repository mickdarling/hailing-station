import Foundation
public import HailProtocol
import OSLog
import Synchronization

// Store, immutable snapshots and serialized session decisions form one host-only boundary.
// swiftlint:disable file_length

/// V1 decisions, pending Mick's answers. Recovery needs authenticated same-device association before advertisement.
public struct HeldRequestPolicy: Sendable {
    public enum Privacy: Sendable { case keep }
    public enum Persistence: Sendable { case memory }
    public enum Reoffer: Sendable { case sameDevice }
    public static let onPrivacy: Privacy = .keep
    public static let persistence: Persistence = .memory
    public static let reoffer: Reoffer = .sameDevice
}

/// Host API only; no capability advertisement or wire controls are enabled.
public enum HeldSendResult: Sendable, Equatable {
    case sent, discarded, stale
    case refused(HeldRequestRefusalReason)
    case held(RequestHeld)
}

/// Uncertain handoffs cannot be sent again until a future reconciliation path establishes their disposition.
public enum HeldDeliveryStatus: Sendable, Equatable { case pending, unresolved, sent, discarded }

struct HeldRequestEntry: Sendable {
    let id: UUID
    let connection: UUID
    let text: String
    let target: String
    let binding: String
    let selection: UUID
    let policy: TargetPolicyGeneration
    let policyRevision: UUID
    let reference: UUID?
    let route: HostSession.VoiceRouted?
    let readBack: ReadBack
    let reasons: [HeldRequestReason]
    let rules: [HeldRequestRule]
    let expires: ContinuousClock.Instant
    let noticeSeconds: Int

    // The snapshot pins every independent authority carried by an ambient dispatch.
    init(id: UUID, connection: UUID, text: String, target: String, binding: String, selection: UUID,
         policy: TargetPolicyGeneration, reference: UUID?, route: HostSession.VoiceRouted?, readBack: ReadBack,
         evidence: HeldReadBackEvidence.Value?, previous: Self?, expires: ContinuousClock.Instant,
         noticeWindow: Duration) {
        self.id = id
        self.connection = connection
        self.text = text
        self.target = target
        self.binding = binding
        self.selection = selection
        self.policy = policy
        policyRevision = evidence?.revision ?? previous?.policyRevision ?? UUID()
        self.reference = reference
        self.route = route
        self.readBack = readBack
        if let evidence, !evidence.reasons.isEmpty { reasons = evidence.reasons } else {
            reasons = previous?.reasons ?? [.confirmTier]
        }
        rules = Array(Set(evidence?.rules ?? previous?.rules ?? [])).sorted { $0.rawValue < $1.rawValue }
        self.expires = evidence?.expires ?? expires
        let seconds = noticeWindow.components.seconds
        noticeSeconds = max(1, min(3_600, Int(seconds)))
    }

    var logDetail: String {
        "reasons=" + reasons.map(\.rawValue).joined(separator: ",")
            + " rules=" + rules.map(\.rawValue).joined(separator: ",")
    }

    var notice: RequestHeld {
        RequestHeld(held: id, reasons: reasons, rules: rules, expiresIn: noticeSeconds)
    }
}

/// Unresolved content is never evicted or purged on teardown. Terminal replay metadata has separate bounds.
actor HeldRequestStore {
    static let perConnection = 8
    static let hostLimit = 64
    static let terminalPerConnection = 32
    static let terminalHostLimit = 256
    private struct Selection {
        let connection: UUID
        let generation: UUID
        var current = true
    }
    nonisolated private let selections = Mutex<[UUID: Selection]>([:])

    // Only active Send attempts register selection metadata; idle and retired connections retain none.
    nonisolated var trackedSelectionCount: Int { selections.withLock { $0.count } }
    nonisolated func trackSelection(_ generation: UUID, connection: UUID) -> UUID {
        let identity = UUID()
        selections.withLock { $0[identity] = Selection(connection: connection, generation: generation) }
        return identity
    }
    nonisolated func select(_ generation: UUID, connection: UUID) {
        selections.withLock { selections in
            for (id, selection) in selections where selection.connection == connection {
                selections[id]?.current = selection.current && selection.generation == generation
            }
        }
    }
    nonisolated func selects(_ identity: UUID) -> Bool {
        selections.withLock { $0[identity]?.current == true }
    }
    nonisolated func endSelection(_ identity: UUID) {
        selections.withLock { $0[identity] = nil }
    }
    nonisolated func retireSelection(connection: UUID) {
        selections.withLock { $0 = $0.filter { $0.value.connection != connection } }
    }
    private var reservations: [UUID: UUID] = [:]
    private(set) var entries: [UUID: HeldRequestEntry] = [:]
    private var terminal: [UUID: (UUID, HeldSendResult)] = [:]
    private var terminalOrder: [UUID] = []
    private struct Decision {
        let id: UUID
        let isSend: Bool
        let task: Task<HeldSendResult, Never>
    }
    private var decisions: [UUID: Decision] = [:]
    private var running: [UUID: UUID] = [:]
    // An uncertain handoff must be reconciled; a second explicit Send cannot risk a duplicate.
    private var unresolved: Set<UUID> = []
    private let logger = Logger(subsystem: "com.mickdarling.hailing-station", category: "held-requests")

    func reserve(connection: UUID) -> UUID? {
        let owned = entries.values.filter { $0.connection == connection }.count
            + reservations.values.filter { $0 == connection }.count
        guard owned < Self.perConnection, entries.count + reservations.count < Self.hostLimit else { return nil }
        let id = UUID()
        reservations[id] = connection
        return id
    }
    func release(_ reservation: UUID) { reservations[reservation] = nil }

    func hold(_ entry: HeldRequestEntry, reservation: UUID?) -> RequestHeld? {
        if let reservation {
            guard reservations[reservation] == entry.connection, entries[entry.id] == nil else { return nil }
            reservations[reservation] = nil
        } else {
            guard entries[entry.id]?.connection == entry.connection else { return nil }
        }
        entries[entry.id] = entry
        let detail = entry.logDetail
        logger.notice("ambient_request_held \(detail, privacy: .public)")
        return entry.notice
    }

    func send(_ id: UUID, from connection: UUID,
              attempt: @escaping @Sendable (HeldRequestEntry) async -> HeldSendResult) async -> HeldSendResult {
        await queueSend(id, from: connection, attempt: attempt).value
    }

    func queueSend(_ id: UUID, from connection: UUID,
                   attempt: @escaping @Sendable (HeldRequestEntry) async -> HeldSendResult
    ) -> Task<HeldSendResult, Never> {
        queueDecision(id, from: connection, attempt: attempt)
    }

    func queueDiscard(_ id: UUID, from connection: UUID) -> Task<HeldSendResult, Never> {
        queueDecision(id, from: connection, attempt: nil)
    }

    private func queueDecision(
        _ id: UUID, from connection: UUID,
        attempt: (@Sendable (HeldRequestEntry) async -> HeldSendResult)?
    ) -> Task<HeldSendResult, Never> {
        if let final = terminal[id] { return Task { final.0 == connection ? final.1 : .stale } }
        guard entries[id]?.connection == connection else { return Task { .stale } }
        let previous = decisions[id]
        if let previous, previous.isSend == (attempt != nil) { return previous.task }
        let identity = UUID()
        let task = Task {
            // Each queued decision observes the state left by its predecessor, including a refused Send.
            if let previous { _ = await previous.task.value }
            return await self.decide(id, connection: connection, identity: identity, attempt: attempt)
        }
        decisions[id] = Decision(id: identity, isSend: attempt != nil, task: task)
        return task
    }

    private func decide(
        _ id: UUID, connection: UUID, identity: UUID,
        attempt: (@Sendable (HeldRequestEntry) async -> HeldSendResult)?
    ) async -> HeldSendResult {
        running[id] = identity
        let result: HeldSendResult
        if let final = terminal[id] {
            result = final.0 == connection ? final.1 : .stale
        } else if let entry = entries[id], entry.connection == connection {
            if let attempt {
                result = unresolved.contains(id) ? .refused(.denied) : await attempt(entry)
            } else { result = .discarded }
            logResolution(result, entry: entry)
        } else { result = .stale }
        finish(id, connection: connection, identity: identity, result: result)
        return result
    }

    func markUnresolved(_ id: UUID) { unresolved.insert(id) }

    func status(_ id: UUID, from connection: UUID) -> HeldDeliveryStatus? {
        if let final = terminal[id], final.0 == connection { return final.1 == .sent ? .sent : .discarded }
        guard entries[id]?.connection == connection else { return nil }
        return unresolved.contains(id) ? .unresolved : .pending
    }

    private func logResolution(_ result: HeldSendResult, entry: HeldRequestEntry) {
        let outcome: String
        switch result {
        case .sent: outcome = "sent"
        case .discarded: outcome = "discarded"
        case .stale: outcome = "stale"
        case .held: outcome = "held"
        case .refused(let reason): outcome = "refused:" + reason.rawValue
        }
        let detail = entry.logDetail
        logger.notice("ambient_request_resolution outcome=\(outcome, privacy: .public) \(detail, privacy: .public)")
    }

    private func finish(_ id: UUID, connection: UUID, identity: UUID, result: HeldSendResult) {
        guard running[id] == identity else { return }
        running[id] = nil
        if decisions[id]?.id == identity { decisions[id] = nil }
        if entries[id] != nil, result == .sent || result == .discarded {
            recordTerminal(id, connection: connection, result: result)
            entries[id] = nil
            unresolved.remove(id)
        }
    }

    func discard(_ id: UUID, from connection: UUID) async -> HeldSendResult {
        await queueDiscard(id, from: connection).value
    }
}

extension HeldRequestStore {
    private func recordTerminal(_ id: UUID, connection: UUID, result: HeldSendResult) {
        terminal[id] = (connection, result)
        terminalOrder.append(id)
        let owned = terminalOrder.filter { terminal[$0]?.0 == connection }
        for retired in owned.prefix(max(0, owned.count - Self.terminalPerConnection)) {
            terminal[retired] = nil
            terminalOrder.removeAll { $0 == retired }
        }
        while terminalOrder.count > Self.terminalHostLimit {
            terminal[terminalOrder.removeFirst()] = nil
        }
    }
}

final class HeldReadBackEvidence: Sendable {
    struct Value: Sendable {
        let hash: String
        let revision: UUID
        let expires: ContinuousClock.Instant
        let reasons: [HeldRequestReason]
        let rules: [HeldRequestRule]
    }
    @TaskLocal static var current: HeldReadBackEvidence?
    private let storage = Mutex<Value?>(nil)
    var value: Value? { storage.withLock { $0 } }
    func record(readBackHash: String, revision: UUID, expires: ContinuousClock.Instant,
                reasons: [HeldRequestReason], rules: [HeldRequestRule]) {
        storage.withLock {
            $0 = Value(hash: readBackHash, revision: revision, expires: expires, reasons: reasons, rules: rules)
        }
    }
}

struct HeldSendScope: Sendable {
    @TaskLocal static var current: HeldSendScope?
    let entry: HeldRequestEntry
    let renewOnly: Bool
    let allowed: @Sendable () -> Bool
    let selected: @Sendable () -> Bool
    let noticeCurrent: @Sendable () -> Bool
    let policyCurrent: @Sendable () -> Bool
    let failure = HeldSendFailure()
}

final class HeldSendFailure: Sendable {
    private let storage = Mutex<HeldRequestRefusalReason?>(nil)
    private let attempted = Mutex(false)
    var didAttemptHandoff: Bool { attempted.withLock { $0 } }
    func willHandoff() { attempted.withLock { $0 = true } }
    var reason: HeldRequestRefusalReason? { storage.withLock { $0 } }
    func record(_ error: any Error) {
        if Self.knownUnsent(error) { attempted.withLock { $0 = false } }
        storage.withLock { $0 = Self.refusalReason(error) }
    }

    private static func refusalReason(_ error: any Error) -> HeldRequestRefusalReason {
        switch error {
        case HeldAuthorityError.selectionChanged: return .selectionChanged
        case HeldAuthorityError.connectionLost: return .connectionLost
        case HeldAuthorityError.policyChanged: return .policyChanged
        case HostError.denied(.notAllowed) where HeldSendScope.current?.entry.policy.performIfCurrent({ true }) != true:
            return .policyChanged
        case HostError.denied(.lockdown): return .lockdown
        case HostError.denied(.rateLimited): return .rateLimited
        case HostError.unknownTarget: return .targetUnavailable
        case HostError.denied(.rebound): return .bindingChanged
        case ProviderContractError.capacityExceeded: return .capacity
        default: return .denied
        }
    }
    private static func knownUnsent(_ error: any Error) -> Bool {
        switch error {
        case HostError.denied, HostError.policyUnavailable, HostError.unknownTarget, is RegistryError,
             is ProviderContractError, is HeldAuthorityError, AdapterError.inputPending, AdapterError.rebound,
             PolicyRetiredDelivery.pastedUnsent: return true
        default: return false
        }
    }
}

extension HostSession {
    func discardHeld(_ id: UUID, from connection: UUID) async -> HeldSendResult {
        guard connection == connectionID else { return .stale }
        let hash = await host.heldRequests.entries[id]?.readBack.hash
        let result = await host.heldRequests.discard(id, from: connection)
        if result == .discarded, let hash { await host.cancel(hash) }
        return result
    }

    func sendHeld(_ id: UUID, from connection: UUID) async -> HeldSendResult {
        guard connection == connectionID else { return .stale }
        return await host.heldRequests.send(id, from: connection) { entry in
            await self.attemptHeld(entry)
        }
    }

    private func attemptHeld(_ entry: HeldRequestEntry) async -> HeldSendResult {
        guard case .ready = state else { return .refused(.connectionLost) }
        guard selectionGeneration == entry.selection, covers(entry.target) else { return .refused(.selectionChanged) }
        let store = host.heldRequests
        let selection = store.trackSelection(entry.selection, connection: connectionID)
        defer { store.endSelection(selection) }
        guard let listing = try? await host.registry.listing(),
              let listed = listing.first(where: { $0.info.id == entry.target }), listed.info.alive else {
            return .refused(.targetUnavailable)
        }
        guard listed.binding == entry.binding else { return .refused(.bindingChanged) }
        _ = await host.refreshedPolicy()
        do { try entry.policy.requireCurrent() } catch { return .refused(.policyChanged) }
        guard await host.heldPolicyIsCurrent(entry.policyRevision) else { return .refused(.policyChanged) }
        let snapshot = self.snapshot, connection = connectionID
        let requestClock = self.requestClock, host = self.host
        let scope = HeldSendScope(entry: entry, renewOnly: requestClock() >= entry.expires, allowed: {
            host.heldSendUnlocked() && !snapshot(connection).contains {
                if case .duckMode(on: true, reason: _, expires: _) = $0 { return true }
                return false
            }
        }, selected: { store.selects(selection) },
           noticeCurrent: { requestClock() < entry.expires },
           policyCurrent: { host.heldPolicyIsCurrent(entry.policyRevision) })
        guard scope.selected() else { return .refused(.selectionChanged) }
        guard scope.allowed(), await !host.currentLockdown.isOn else { return .refused(.lockdown) }
        return await HeldSendScope.$current.withValue(scope) {
            await Self.$ambientInputDispatch.withValue(true) {
                await Self.$ambientReplyReference.withValue(entry.reference) {
                    await Self.$voiceRouted.withValue(entry.route) {
                        await self.dispatchHeldEntry(entry, scope: scope)
                    }
                }
            }
        }
    }

    private func dispatchHeldEntry(_ entry: HeldRequestEntry, scope: HeldSendScope) async -> HeldSendResult {
        do {
            let result = try await dispatchResult(LocalDispatchRequest(
                connection: connectionID, target: entry.target, binding: entry.binding, text: entry.text
            ), generation: entry.selection)
            switch result {
            case .delivered: return .sent
            case .held(let notice): return .held(notice)
            case .holdAdmissionRefused: return .refused(.capacity)
            }
        } catch {
            if scope.failure.didAttemptHandoff { await host.heldRequests.markUnresolved(entry.id) }
            if let reason = scope.failure.reason { return .refused(reason) }
            return await heldDispatchFailure(error, entry: entry)
        }
    }

    private func heldDispatchFailure(_ error: any Error, entry: HeldRequestEntry) async -> HeldSendResult {
        switch error {
        case LocalDispatchRefusal.selectionChanged, LocalDispatchRefusal.targetNotSelected:
            return .refused(.selectionChanged)
        case LocalDispatchRefusal.bindingMismatch: return .refused(.bindingChanged)
        case LocalDispatchRefusal.sessionNotReady: return .refused(.connectionLost)
        case LocalDispatchRefusal.ownershipLost, LocalDispatchRefusal.connectionLost:
            await host.heldRequests.markUnresolved(entry.id)
            return .refused(.connectionLost)
        default: return .refused(.denied)
        }
    }
}

/// A listener supplies liveness checks; the session API remains usable for synthetic host tests.
enum HeldPeerScope {
    @TaskLocal static var current: (@Sendable () async -> Bool)?
    static func requireCurrent() async throws {
        if let current, await !current() { throw HeldAuthorityError.connectionLost }
    }
}

enum HeldAuthorityError: Error { case selectionChanged, connectionLost, policyChanged, noticeExpired }
