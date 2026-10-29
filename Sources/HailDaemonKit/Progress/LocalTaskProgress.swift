public import Foundation

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
