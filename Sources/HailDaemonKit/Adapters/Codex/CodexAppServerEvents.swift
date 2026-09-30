#if os(macOS)
import Foundation

private struct CodexItemIdentity: Hashable { let turn: String; let item: String }
private struct CodexActiveTurn {
    let id: String
    let context: ProviderTurnContext
    var accepted = false
}
/// Exact-ID reconciliation only; no visibility inference, delta reconstruction or arrival-order attribution.
struct CodexAppServerEvents {
    let binding: ProviderSessionBinding
    let threadID: String
    private var pending: ProviderTurnContext?
    private var active: CodexActiveTurn?
    private var early: [CodexAppServerRecord] = []
    private var earlyBytes = 0
    private var turns = Set<String>()
    private var terminals: [String: ProviderEventKind] = [:]
    private var contexts = Set<UUID>()
    private var items: [CodexItemIdentity: Data] = [:]
    private var sequence = 0
    var bufferedEarlyRecords: Int { early.count }

    init(binding: ProviderSessionBinding, threadID: String) { self.binding = binding; self.threadID = threadID }
    mutating func begin(_ context: ProviderTurnContext) throws {
        guard context.binding == binding else { throw ProviderContractError.wrongContext }
        guard pending == nil, active == nil else { throw CodexAppServerError.turnInProgress }
        guard !contexts.contains(context.id) else { throw ProviderContractError.duplicateTurn }
        guard contexts.count < 64, items.count < 256 else { throw CodexAppServerError.capacityExceeded }
        contexts.insert(context.id); pending = context
    }
    mutating func bind(_ id: String) throws -> [ProviderSessionEvent] {
        guard let pending, !turns.contains(id) else { throw CodexAppServerError.invalidProtocol }
        guard turns.count < 64 else { throw CodexAppServerError.capacityExceeded }
        // Validate the entire held prefix before accepting any of its output.
        guard early.allSatisfy({ $0.threadID == threadID && $0.turnID == id }) else {
            throw CodexAppServerError.invalidProtocol
        }
        turns.insert(id); active = CodexActiveTurn(id: id, context: pending); self.pending = nil
        let records = early; early.removeAll(); earlyBytes = 0
        var events: [ProviderSessionEvent] = []
        for record in records { if let event = try mapped(record) { events.append(event) } }
        return events
    }
    mutating func receive(_ record: CodexAppServerRecord) throws -> [ProviderSessionEvent] {
        guard record.threadID == threadID else { throw CodexAppServerError.invalidProtocol }
        if try duplicateItem(record) || duplicateTerminal(record) { return [] }
        if active?.id != record.turnID, turns.contains(record.turnID) { return [] } // Ended tombstone.
        if pending != nil {
            guard early.count < 16, record.bytes <= 32_768 - earlyBytes else {
                throw CodexAppServerError.capacityExceeded
            }
            early.append(record); earlyBytes += record.bytes; return []
        }
        guard active?.id == record.turnID else { throw CodexAppServerError.invalidProtocol }
        return try mapped(record).map { [$0] } ?? []
    }
    private func duplicateItem(_ record: CodexAppServerRecord) throws -> Bool {
        guard case .item(let id, _, let fingerprint) = record.kind,
              let previous = items[CodexItemIdentity(turn: record.turnID, item: id)] else { return false }
        guard previous == fingerprint else { throw CodexAppServerError.invalidProtocol }
        return true
    }
    private func duplicateTerminal(_ record: CodexAppServerRecord) throws -> Bool {
        guard case .terminal(let kind) = record.kind, let previous = terminals[record.turnID] else { return false }
        guard previous == kind else { throw CodexAppServerError.invalidProtocol }
        return true
    }
    private mutating func mapped(_ record: CodexAppServerRecord) throws -> ProviderSessionEvent? {
        if try duplicateItem(record) || duplicateTerminal(record) { return nil }
        guard let active else { return nil } // The checked early suffix cannot revive an ended turn.
        let kind: ProviderEventKind
        switch record.kind {
        case .accepted:
            guard !active.accepted else { return nil }
            self.active?.accepted = true; kind = .accepted
        case .item(let id, let text, let fingerprint):
            guard active.accepted else { throw CodexAppServerError.invalidProtocol }
            guard let item = try item(id, text: text, turn: active.id, fingerprint: fingerprint) else { return nil }
            kind = item
        case .terminal(let terminal):
            guard active.accepted else { throw CodexAppServerError.invalidProtocol }
            kind = terminal; terminals[active.id] = terminal; self.active = nil
        }
        guard sequence < ProviderEventLimits.maxRetainedEvents else { throw CodexAppServerError.capacityExceeded }
        let event = try ProviderSessionEvent(binding: binding, sequence: sequence, turn: active.context, kind: kind)
        sequence += 1; return event
    }
    private mutating func item(_ id: String, text: String?, turn: String, fingerprint: Data) throws
        -> ProviderEventKind? {
        let identity = CodexItemIdentity(turn: turn, item: id)
        if let previous = items[identity] {
            guard previous == fingerprint else { throw CodexAppServerError.invalidProtocol }
            return nil
        }
        guard items.count < 256 else { throw CodexAppServerError.capacityExceeded }
        items[identity] = fingerprint
        return text.map { .text($0, isFinal: true, visibility: .userVisible) }
    }
}
#endif
