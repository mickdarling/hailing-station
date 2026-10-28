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
        var revoked = false, eof = false
    }
    private let state = Mutex(State())
    private let child: OwnedStdioChild
    let request: UUID, generation: UUID
    init(command: OwnedStdioCommand, request: UUID, generation: UUID) throws {
        self.request = request; self.generation = generation
        child = try OwnedStdioChild(command: command)
        Task { await read() }
    }
    var report: CodexRecoveryReport? {
        state.withLock { state in
            guard !state.revoked, let latest = state.latest,
                  !latest.state.terminal || state.eof else { return nil }
            return latest
        }
    }
    var stopped: Bool { state.withLock { $0.revoked || $0.eof } }
    var reaped: Bool { child.isReaped }
    func stop() { state.withLock { $0.revoked = true }; child.cancel() }
    func join() async { await child.join() }
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
            while ContinuousClock().now < deadline {
                let snapshot = state.withLock { ($0.revoked, $0.eof, $0.latest) }
                guard !snapshot.0 else { throw CodexRecoveryFault.stopped }
                if let latest = snapshot.2 {
                    if phases.contains(latest.state), latest.state.terminal ? snapshot.1 : !snapshot.1 { return latest }
                    if latest.state.terminal, snapshot.1 { throw CodexRecoveryFault.unavailable }
                }
                guard !snapshot.1 else { throw CodexRecoveryFault.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            stop(); throw CodexRecoveryFault.timeout
        } onCancel: { stop() }
    }
    private func read() async {
        do {
            for try await chunk in child.chunks {
                try accept(chunk)
            }
            let incomplete = state.withLock { state in
                state.eof = true
                let invalid = !state.pending.isEmpty || state.latest?.state.terminal != true
                if invalid { state.revoked = true }
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
