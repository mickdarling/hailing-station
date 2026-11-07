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

struct HeldRequestEntry: Sendable {
    let id: UUID
    let connection: UUID
    let text: String
    let target: String
    let binding: String
    let selection: UUID
    let policy: TargetPolicyGeneration
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
        self.reference = reference
        self.route = route
        self.readBack = readBack
        if let evidence, !evidence.reasons.isEmpty { reasons = evidence.reasons } else {
            reasons = previous?.reasons ?? [.confirmTier]
        }
        rules = Array(Set(evidence?.rules ?? previous?.rules ?? [])).sorted { $0.rawValue < $1.rawValue }
        self.expires = expires
        let seconds = noticeWindow.components.seconds
        noticeSeconds = max(1, min(3_600, Int(seconds)))
    }

    var notice: RequestHeld {
        RequestHeld(held: id, reasons: reasons, rules: rules, expiresIn: noticeSeconds)
    }
}

/// No eviction, expiry purge or connection teardown purge. Reservations count against the same bounds as holds.
actor HeldRequestStore {
    static let perConnection = 8
    static let hostLimit = 64
    nonisolated private let selections = Mutex<[UUID: UUID]>([:])
    nonisolated func select(_ generation: UUID, connection: UUID) {
        selections.withLock { $0[connection] = generation }
    }
    nonisolated func selects(_ generation: UUID, connection: UUID) -> Bool {
        selections.withLock { $0[connection] == generation }
    }
    private var reservations: [UUID: UUID] = [:]
    private(set) var entries: [UUID: HeldRequestEntry] = [:]
    private var terminal: [UUID: (UUID, HeldSendResult)] = [:]
    private var running: [UUID: Task<HeldSendResult, Never>] = [:]
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

    func hold(_ entry: HeldRequestEntry, reservation: UUID?) -> RequestHeld {
        if let reservation { reservations[reservation] = nil }
        entries[entry.id] = entry
        let reasons = entry.reasons.map(\.rawValue).joined(separator: ",")
        let rules = entry.rules.map(\.rawValue).joined(separator: ",")
        logger.notice("ambient_request_held reasons=\(reasons, privacy: .public) rules=\(rules, privacy: .public)")
        return entry.notice
    }

    func send(_ id: UUID, from connection: UUID,
              attempt: @escaping @Sendable (HeldRequestEntry) async -> HeldSendResult) async -> HeldSendResult {
        if let final = terminal[id] { return final.0 == connection ? final.1 : .stale }
        guard let entry = entries[id], entry.connection == connection else { return .stale }
        if let task = running[id] { return await task.value }
        guard !unresolved.contains(id) else { return .refused(.denied) }
        let task = Task { await attempt(entry) }
        running[id] = task
        let result = await task.value
        finish(id, connection: connection, result: result)
        return result
    }

    func markUnresolved(_ id: UUID) { unresolved.insert(id) }

    private func finish(_ id: UUID, connection: UUID, result: HeldSendResult) {
        running[id] = nil
        if result == .sent || result == .discarded {
            terminal[id] = (connection, result)
            entries[id] = nil
            unresolved.remove(id)
        }
    }

    func discard(_ id: UUID, from connection: UUID) async -> HeldSendResult {
        if let final = terminal[id] { return final.0 == connection ? final.1 : .stale }
        guard entries[id]?.connection == connection else { return .stale }
        if let task = running[id] {
            let result = await task.value
            finish(id, connection: connection, result: result)
            return await discard(id, from: connection)
        }
        finish(id, connection: connection, result: .discarded)
        return .discarded
    }
}

final class HeldReadBackEvidence: Sendable {
    struct Value: Sendable {
        let hash: String
        let reasons: [HeldRequestReason]
        let rules: [HeldRequestRule]
    }
    @TaskLocal static var current: HeldReadBackEvidence?
    private let storage = Mutex<Value?>(nil)
    var value: Value? { storage.withLock { $0 } }
    func record(readBackHash: String, reasons: [HeldRequestReason], rules: [HeldRequestRule]) {
        storage.withLock { $0 = Value(hash: readBackHash, reasons: reasons, rules: rules) }
    }
}

struct HeldSendScope: Sendable {
    @TaskLocal static var current: HeldSendScope?
    let entry: HeldRequestEntry
    let renewOnly: Bool
    let allowed: @Sendable () -> Bool
    let failure = HeldSendFailure()
}

final class HeldSendFailure: Sendable {
    private let storage = Mutex<HeldRequestRefusalReason?>(nil)
    var reason: HeldRequestRefusalReason? { storage.withLock { $0 } }
    func record(_ error: any Error) {
        let reason: HeldRequestRefusalReason
        switch error {
        case HostError.denied(.lockdown): reason = .lockdown
        case HostError.denied(.rateLimited): reason = .rateLimited
        case HostError.unknownTarget: reason = .targetUnavailable
        case HostError.denied(.rebound): reason = .bindingChanged
        case ProviderContractError.capacityExceeded: reason = .capacity
        default: reason = .denied
        }
        storage.withLock { $0 = reason }
    }
}

extension HostSession {
    func discardHeld(_ id: UUID, from connection: UUID) async -> HeldSendResult {
        guard connection == connectionID else { return .stale }
        return await host.heldRequests.discard(id, from: connection)
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
        guard let listing = try? await host.registry.listing(),
              let listed = listing.first(where: { $0.info.id == entry.target }), listed.info.alive else {
            return .refused(.targetUnavailable)
        }
        guard listed.binding == entry.binding else { return .refused(.bindingChanged) }
        _ = await host.refreshedPolicy()
        do { try entry.policy.requireCurrent() } catch { return .refused(.policyChanged) }
        let snapshot = self.snapshot, connection = connectionID, store = host.heldRequests
        let scope = HeldSendScope(entry: entry, renewOnly: requestClock() >= entry.expires, allowed: {
            store.selects(entry.selection, connection: connection)
                && !snapshot(connection).contains {
                    if case .duckMode(on: true, reason: _, expires: _) = $0 { return true }
                    return false
                }
        })
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
            if let reason = scope.failure.reason { return .refused(reason) }
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
}
