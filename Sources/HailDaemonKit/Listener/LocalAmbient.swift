public import Foundation
import OSLog

private let ambientLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "local-ambient")

/// `haild ambient reload|status` over the owner-only local reply socket (#405). Local only: it never starts
/// listening, never touches a device, and only re-arms a stream the phone already has on.
public struct LocalAmbientRequest: Codable, Sendable, Equatable {
    public static let kind = "ambient"

    public enum Action: String, Codable, Sendable, CaseIterable {
        case reload, status
    }

    public var action: Action

    public init(action: Action) { self.action = action }

    private enum CodingKeys: String, CodingKey { case kind, action }

    /// Exactly `{"kind":"ambient","action":"reload"|"status"}`: any other key or value is refused.
    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == Self.kind else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "not ambient")
        }
        guard Set(keys) == ["kind", "action"], keys.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "unknown key")
        }
        action = try container.decode(Action.self, forKey: .action)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(action, forKey: .action)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// The daemon's answer to a local ambient request (#405): an outcome token plus ids, times and counts. Never
/// transcript text, audio or the device's name.
public struct LocalAmbientReport: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// A fresh child serves the active stream.
        case reloaded
        /// No active stream: nothing was started.
        case idle
        /// A start, another reload or a full child slot is in the way, or the stream changed meanwhile.
        case busy
        /// The daemon is shutting down.
        case stopping
        /// The new child could not be launched; the old one keeps the stream. `reason` names the rule.
        case refused
        /// A status answer.
        case status
        /// The daemon runs without `--ambient-rightyo`.
        case notEnabled = "not_enabled"
    }

    public var outcome: Outcome
    public var reason: String?
    public var active: Bool
    /// The streaming device's class from its hello (`phone`, `pad`, …), when it gave one.
    public var deviceClass: String?
    public var target: String?
    public var since: Date?
    public var childSince: Date?
    public var installedAt: Date?
    public var liveChildren: Int

    public init(outcome: Outcome, reason: String? = nil, active: Bool = false, deviceClass: String? = nil,
                target: String? = nil, since: Date? = nil, childSince: Date? = nil, installedAt: Date? = nil,
                liveChildren: Int = 0) {
        (self.outcome, self.reason, self.active, self.deviceClass) = (outcome, reason, active, deviceClass)
        (self.target, self.since, self.childSince) = (target, since, childSince)
        (self.installedAt, self.liveChildren) = (installedAt, liveChildren)
    }
}

extension WebSocketListener {
    /// Forwards a local ambient request to the ambient wiring (#405); without one, ambient is not enabled.
    public func ambient(_ request: LocalAmbientRequest) async -> LocalAmbientReport {
        guard let ambient else { return LocalAmbientReport(outcome: .notEnabled) }
        guard !stopped else { return LocalAmbientReport(outcome: .stopping) }
        var report: LocalAmbientReport
        switch request.action {
        case .status:
            report = LocalAmbientReport(outcome: .status)
        case .reload:
            switch await ambient.reload() {
            case .reloaded: report = LocalAmbientReport(outcome: .reloaded)
            case .idle: report = LocalAmbientReport(outcome: .idle)
            case .busy: report = LocalAmbientReport(outcome: .busy)
            case .stopping: report = LocalAmbientReport(outcome: .stopping)
            case .refused(let reason): report = LocalAmbientReport(outcome: .refused, reason: reason)
            }
        }
        let status = ambient.status()
        report.active = status.connection != nil
        (report.target, report.since, report.childSince) = (status.target, status.streamSince, status.childSince)
        (report.installedAt, report.liveChildren) = (status.installedAt, status.liveChildren)
        if let connection = status.connection,
           let peer = peers.values.first(where: { $0.session.connectionID == connection }) {
            report.deviceClass = await peer.session.peerDeviceKind
        }
        return report
    }
}

extension LocalReplyEndpoint {
    /// Same admission budget and fail-closed audit as a dispatch (`pushed(tool: "local-ambient")`, the action in
    /// place of a target). Content-free in both directions.
    func submitAmbient(_ data: Data, from client: LocalReplyConnection) async {
        do {
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let request: LocalAmbientRequest
            do { request = try JSONDecoder().decode(LocalAmbientRequest.self, from: data) } catch {
                ambientLogger.error("Local ambient decode failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.decodeFailure
            }
            do {
                _ = try await audit.record(.pushed(tool: "local-ambient", target: request.action.rawValue,
                                                   bytes: data.count))
            } catch {
                ambientLogger.error("Local ambient audit failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.auditFailure
            }
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let report = await destination.ambient(request)
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            await respond(.ambient(report), to: client)
        } catch is CancellationError {
            retire(client.id)
        } catch {
            let reason = LocalReplyRefusal(error)
            guard !stopped, connections[client.id] != nil else { return retire(client.id) }
            await respond(.init(delivered: 0, error: reason.message, code: reason), to: client)
        }
    }
}
