public import Foundation
import Synchronization

enum TaskProgressOwnerControlScope {
    @TaskLocal static var beforeValidation: (@Sendable (TaskProgressTask) async -> Void)?
}

enum TaskProgressControllerLifetimeScope {
    @TaskLocal static var beforeWake: (@Sendable (TaskProgressWake) async -> Void)?
    @TaskLocal static var beforeReportCleanup: (@Sendable (TaskProgressWake) async -> Void)?
}

struct TaskProgressOwnerLease: Sendable {
    let task: TaskProgressTask
    let generation: UUID
}

/// Listener shutdown is independent of output quiet/media holds, which must not disable owner controls.
final class TaskProgressOwnerLifetime: Sendable {
    private let open = Mutex(true)
    func close() { open.withLock { $0 = false } }
    func perform(_ commit: () -> TaskProgressControlResult) -> TaskProgressControlResult {
        open.withLock { $0 ? commit() : .noTask }
    }
}

/// Synchronous enrollment identity shared with final scheduler admission; task UUID reuse cannot renew a lease.
final class TaskProgressOwnerState: Sendable {
    private struct State {
        var task: TaskProgressTask?
        var generation = UUID()
        var fence = TaskProgressOutputFence()
        var reserved = false
    }
    private let state = Mutex(State())
    var fence: TaskProgressOutputFence { state.withLock { $0.fence } }

    func reserveStart() -> UUID? {
        state.withLock {
            guard $0.task == nil, !$0.reserved else { return nil }
            $0.reserved = true
            $0.generation = UUID()
            return $0.generation
        }
    }

    func cancelStart(_ generation: UUID? = nil) {
        state.withLock {
            guard $0.reserved, generation == nil || $0.generation == generation else { return }
            $0.reserved = false
            $0.generation = UUID()
        }
    }

    func enroll(_ task: TaskProgressTask, reservation: UUID,
                lifetime: TaskProgressOwnerLifetime) -> TaskProgressOwnerLease? {
        state.withLock { state in
            guard state.reserved, state.task == nil, state.generation == reservation else { return nil }
            let admitted = lifetime.perform {
                state.fence.close()
                state.task = task
                state.reserved = false
                state.fence = TaskProgressOutputFence()
                return .applied
            }
            return admitted == .applied ? .init(task: task, generation: reservation) : nil
        }
    }

    @discardableResult
    func retire(_ lease: TaskProgressOwnerLease) -> Bool {
        state.withLock {
            guard $0.task == lease.task, $0.generation == lease.generation else { return false }
            $0.fence.close()
            $0.task = nil
            return true
        }
    }

    func isCurrent(_ lease: TaskProgressOwnerLease) -> Bool {
        state.withLock { $0.task == lease.task && $0.generation == lease.generation }
    }

    func isRetired(_ lease: TaskProgressOwnerLease) -> Bool {
        state.withLock { $0.task == nil && $0.generation == lease.generation }
    }

    func withCurrent(_ lease: TaskProgressOwnerLease,
                     commit: () -> TaskProgressControlResult) -> TaskProgressControlResult {
        state.withLock {
            guard $0.task == lease.task, $0.generation == lease.generation else { return .noTask }
            return commit()
        }
    }

    func lease(for task: TaskProgressTask) -> TaskProgressOwnerLease? {
        state.withLock { $0.task == task ? .init(task: task, generation: $0.generation) : nil }
    }

    func perform(_ lease: TaskProgressOwnerLease, control: TaskProgressOwnerControl,
                 commit: () -> TaskProgressControlResult) -> TaskProgressControlResult {
        state.withLock { state in
            guard state.task == lease.task, state.generation == lease.generation else { return .noTask }
            let result = commit()
            // The stream/lifetime locks are already released. Never invert publication's fence->router order.
            if result == .applied {
                switch control {
                case .pause, .stop: state.fence.close()
                case .resume: state.fence = TaskProgressOutputFence()
                default: break
                }
            }
            return result
        }
    }
}

/// Owner-local controls on the existing private socket. These are cooperative controls, like `notify quiet`;
/// the source label is not proof of which local process spoke. No request reference is accepted (#1013).
public struct LocalTaskProgressRequest: Codable, Sendable, Equatable {
    public static let kind = "task_progress"
    public enum Action: String, Codable, Sendable { case start, status, interval, owner, report, finish, cancel }
    public var kind = Self.kind
    public var action: Action
    public var target: String?
    public var task: UUID?
    public var token: UUID?
    public var seconds: Int?
    public var command: String?
    public var text: String?
    public var card: String?

    public init(action: Action, target: String? = nil, task: UUID? = nil, token: UUID? = nil,
                seconds: Int? = nil, command: String? = nil, text: String? = nil, card: String? = nil) {
        self.action = action
        (self.target, self.task, self.token) = (target, task, token)
        (self.seconds, self.command, self.text, self.card) = (seconds, command, text, card)
    }

    /// Reject unknown and irrelevant fields before an action can change state.
    public static func decode(_ data: Data) throws -> Self {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let value = try JSONDecoder().decode(Self.self, from: data)
        let fields: Set<String>
        switch value.action {
        case .start: fields = ["target", "task", "seconds"]
        case .status: fields = []
        case .interval: fields = ["task", "seconds"]
        case .owner: fields = ["task", "command"]
        case .report: fields = ["task", "token", "text", "card"]
        case .finish: fields = ["task", "text", "card"]
        case .cancel: fields = ["task"]
        }
        guard value.kind == Self.kind, let object,
              Set(object.keys).isSubset(of: fields.union(["kind", "action"])) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }
}

/// Counts, timing and state only; never the target's private binding or the update's words.
public struct LocalTaskProgressReport: Codable, Sendable, Equatable {
    public var outcome: String
    public var task: UUID?
    public var session: String?
    public var intervalSeconds: Int?
    public var setBy: String?
    public var pauseReason: String?
    public var nextDueInSeconds: Int?
    public var outstanding = false
    public var reason: String?
    public var update: LocalSessionUpdateReport?

    public init(outcome: String, reason: String? = nil) { (self.outcome, self.reason) = (outcome, reason) }
}

extension LocalReplyEndpoint {
    func submitTaskProgress(_ data: Data, from client: LocalReplyConnection) async {
        do {
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let request = try LocalTaskProgressRequest.decode(data)
            _ = try await audit.record(.pushed(tool: "local-progress", target: request.action.rawValue,
                                             bytes: data.count))
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let report = await destination.taskProgress(request)
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            await respond(.progress(report), to: client)
        } catch is CancellationError {
            retire(client.id)
        } catch {
            guard !stopped, connections[client.id] != nil else { return retire(client.id) }
            await respond(.init(delivered: 0, error: "task progress refused"), to: client)
        }
    }
}
