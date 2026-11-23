#if os(macOS)
import Foundation
import Synchronization

/// Private worker states, never provider text or free-form errors.
enum CodexRecoveryPhase: String, Sendable, Codable, CaseIterable {
    case ready, waiting, working, interrupted, completed, failed, retired, unavailable
    case awaitingChildAck = "awaiting_child_ack", alreadyAttempted = "already_attempted"
    case commitUnconfirmed = "commit_unconfirmed", requestUnobserved = "request_unobserved"
    case childAckUnconfirmed = "child_ack_unconfirmed", invalidControl = "invalid_control"
    case completedRace = "completed_race"
    var terminal: Bool { ![.ready, .waiting, .working, .awaitingChildAck].contains(self) }
}
struct CodexRecoveryReport: Sendable, Decodable {
    let version: Int, state: CodexRecoveryPhase, request: UUID, generation: UUID
    let recovered: Bool
}

/// Reuses the exact-child pipe/reap primitive. This launches only the recovery worker, never Codex or capture.
final class CodexRecoveryChannel: Sendable {
    private struct State {
        var pending = Data()
        var latest: CodexRecoveryReport?
        var revoked = false
        var eofAt: ContinuousClock.Instant?
        var reader: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let child: OwnedStdioChild
    let request: UUID, generation: UUID
    init(command: OwnedStdioCommand, request: UUID, generation: UUID) throws {
        self.request = request; self.generation = generation
        child = try OwnedStdioChild(command: command)
        state.withLock { $0.reader = Task { await self.read() } }
    }
    var report: CodexRecoveryReport? {
        state.withLock { state in
            guard !state.revoked, let latest = state.latest,
                  !latest.state.terminal || state.eofAt != nil else { return nil }
            return latest
        }
    }
    var stopped: Bool { state.withLock { $0.revoked || $0.eofAt != nil } }
    var reaped: Bool { child.isReaped }
    func stop() { state.withLock { $0.revoked = true }; child.cancel() }
    func join() async {
        let reader = state.withLock { $0.reader }
        await reader?.value
        await child.join()
    }
    func send(_ operation: String) async throws {
        guard ["prepare", "commit", "authorize", "retire"].contains(operation), !stopped else {
            throw CodexRecoveryFault.stopped
        }
        let fields: [String: Any] = ["version": 1, "op": operation, "request": request.uuidString.lowercased(),
                                     "generation": generation.uuidString.lowercased()]
        var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        data.append(10)
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await child.write(data)
                try Task.checkCancellation()
            } catch { stop(); throw CodexRecoveryFault.unavailable }
        } onCancel: { stop() }
    }
    func wait(for phases: Set<CodexRecoveryPhase>, until deadline: ContinuousClock.Instant) async throws
        -> CodexRecoveryReport {
        try await withTaskCancellationHandler {
            while true {
                let (revoked, eofAt, latest, now) = state.withLock {
                    ($0.revoked, $0.eofAt, $0.latest, ContinuousClock.now)
                }
                guard !revoked else { throw CodexRecoveryFault.stopped }
                // A delayed waiter can consume terminal proof validated before its deadline.
                if let eofAt, eofAt <= deadline {
                    guard let latest, latest.state.terminal, phases.contains(latest.state) else {
                        throw CodexRecoveryFault.unavailable
                    }
                    return latest
                }
                guard now < deadline else { stop(); throw CodexRecoveryFault.timeout }
                if let latest, !latest.state.terminal, phases.contains(latest.state) { return latest }
                try await Task.sleep(for: .milliseconds(20))
            }
        } onCancel: { stop() }
    }
    private func read() async {
        do {
            for try await chunk in child.chunks {
                try accept(chunk)
            }
            let incomplete = state.withLock { state in
                let invalid = !state.pending.isEmpty || state.latest?.state.terminal != true
                if invalid { state.revoked = true }
                state.eofAt = .now
                return invalid
            }
            if incomplete { stop() }
        } catch { stop() }
    }
    private func accept(_ chunk: Data) throws {
        try state.withLock { state in
            do {
                guard !state.revoked, state.pending.count + chunk.count <= 8192 else {
                    throw CodexRecoveryFault.unavailable
                }
                state.pending.append(chunk)
                while let end = state.pending.firstIndex(of: 10) {
                    let line = state.pending.prefix(upTo: end)
                    state.pending.removeSubrange(...end)
                    guard !line.isEmpty, line.count <= 1024,
                          let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          Set(object.keys) == ["version", "state", "request", "generation", "recovered"] else {
                        throw CodexRecoveryFault.unavailable
                    }
                    let value = try JSONDecoder().decode(CodexRecoveryReport.self, from: line)
                    guard state.latest?.state.terminal != true, value.version == 1,
                          value.request == request, value.generation == generation,
                          !value.recovered || value.state == .interrupted else { throw CodexRecoveryFault.unavailable }
                    state.latest = value
                }
                guard state.pending.count <= 1024 else { throw CodexRecoveryFault.unavailable }
            } catch { state.revoked = true; throw error }
        }
    }
}
#endif
