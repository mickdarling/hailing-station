import Foundation
import OSLog

private let updateLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "local-update")

/// `haild notify` over the owner-only local reply socket (#609): a local session's unsolicited update, the quiet
/// switch, or a status question. The speaking session is a live target the registry lists, never free text, so it
/// cannot dodge its budget or pose as another session. Exactly the keys the action uses; anything else is refused.
public struct LocalSessionUpdateRequest: Codable, Sendable, Equatable {
    public static let kind = "update"

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// `submit` speaks now or holds, by the policy. `hold` holds an update whose immediate speech failed, without
        /// spending budget again. `announce` (#605) speaks only on a listening device and never holds.
        case submit, hold, announce
        /// The do-not-disturb switch, until haild restarts.
        case quietOn = "quiet_on", quietOff = "quiet_off"
        case status

        var carriesUpdate: Bool { [.submit, .hold, .announce].contains(self) }
    }

    public var action: Action
    public var target: String?
    public var priority: SessionUpdatePriority?
    public var text: String?
    public var card: String?

    public init(action: Action, target: String? = nil, priority: SessionUpdatePriority? = nil, text: String? = nil,
                card: String? = nil) {
        (self.action, self.target, self.priority, self.text, self.card) = (action, target, priority, text, card)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, action, target, priority, text, card }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        let keys = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
        let allowed = action.carriesUpdate ? Set(CodingKeys.allCases.map(\.rawValue)) : ["kind", "action"]
        guard try container.decode(String.self, forKey: .kind) == Self.kind, keys.isSubset(of: allowed) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "not an update")
        }
        target = try container.decodeIfPresent(String.self, forKey: .target)
        priority = try container.decodeIfPresent(SessionUpdatePriority.self, forKey: .priority)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        card = try container.decodeIfPresent(String.self, forKey: .card)
        guard !action.carriesUpdate || (target != nil && text != nil) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "missing key")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.kind, forKey: .kind)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(card, forKey: .card)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// The daemon's answer to a local update request (#609): an outcome token and counts. Never the update's text.
public struct LocalSessionUpdateReport: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// `speak`: deliver it now through the reply path (`haild reply --say`), and send `hold` if that fails.
        /// `held`: kept for a natural pause, "any updates?", or the next interaction. `not_listening`: an announce
        /// found no listening device, or quiet or media mode is on; nothing was held. `status`: a status or quiet
        /// answer. `not_enabled`: haild runs without `--session-updates`.
        case speak, held, notListening = "not_listening", refused, status, notEnabled = "not_enabled"
    }

    public var outcome: Outcome
    /// For `refused`: `disabled`, `rate_limited`, `full`, `expired`, `unknown_target`, `invalid` or `stopping`.
    public var reason: String?
    /// Whole seconds until the session may send again, for `rate_limited`.
    public var retryAfter: Int?
    /// A held `action` update: the caller may raise its own push notification too.
    public var push = false
    public var held = 0
    public var quiet = false

    public init(outcome: Outcome, reason: String? = nil) { (self.outcome, self.reason) = (outcome, reason) }
}

extension WebSocketListener {
    /// `--session-updates` (#609): sessions may send updates. Off by default.
    func enableSessionUpdates() { sessionUpdates.policy.enabled = true }

    /// Applies the update policy to a local request (#609). The text is neither logged nor audited.
    public func sessionUpdate(_ request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        guard sessionUpdates.policy.enabled else { return LocalSessionUpdateReport(outcome: .notEnabled) }
        guard !stopped else { return updateReport(.refused, reason: "stopping") }
        switch request.action {
        case .status: return updateReport(.status)
        case .quietOn, .quietOff:
            sessionUpdatesQuiet = request.action == .quietOn
            return updateReport(.status)
        case .submit, .hold, .announce: return await sessionUpdate(carried: request)
        }
    }

    private func sessionUpdate(carried request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        guard let target = request.target, let listing = try? await host.registry.listing(),
              listing.contains(where: { $0.info.id == target && $0.info.alive }) else {
            return updateReport(.refused, reason: "unknown_target")
        }
        let now = ContinuousClock.now
        let priority = request.action == .announce ? .action : request.priority ?? .info
        guard !stopped, let update = SessionUpdate(session: target, priority: priority, spoken: request.text ?? "",
                                                   card: request.card, submitted: now) else {
            return updateReport(.refused, reason: stopped ? "stopping" : "invalid")
        }
        let audience = updateAudience(for: target)
        switch request.action {
        case .hold: return decided(sessionUpdates.hold(update, audience: audience, at: now))
        case .announce where audience.listeningDevice == nil || audience.quiet || audience.media:
            return updateReport(.notListening)
        default: return decided(sessionUpdates.submit(update, audience: audience, now: now))
        }
    }

    /// The listening device, else the device that last sent `target` input (#370), and that device's media mode.
    func updateAudience(for target: String) -> SessionUpdateAudience {
        var audience = SessionUpdateAudience(listeningDevice: ambient?.activeConnection(),
                                             lastActiveDevice: lastInput.latest(for: target)?.connection,
                                             quiet: sessionUpdatesQuiet)
        audience.media = audience.target.map { ambient?.mediaMode(connection: $0) ?? false } ?? false
        return audience
    }

    private func decided(_ decision: SessionUpdateDecision) -> LocalSessionUpdateReport {
        switch decision {
        case .speak: return updateReport(.speak)
        case .held(let push):
            var report = updateReport(.held)
            report.push = push != nil
            return report
        case .refused(.disabled): return updateReport(.refused, reason: "disabled")
        case .refused(.full): return updateReport(.refused, reason: "full")
        case .refused(.expired): return updateReport(.refused, reason: "expired")
        case .refused(.rateLimited(let wait)):
            var report = updateReport(.refused, reason: "rate_limited")
            report.retryAfter = Int(wait.components.seconds) + (wait.components.attoseconds > 0 ? 1 : 0)
            return report
        }
    }

    private func updateReport(_ outcome: LocalSessionUpdateReport.Outcome, reason: String? = nil)
        -> LocalSessionUpdateReport {
        var report = LocalSessionUpdateReport(outcome: outcome, reason: reason)
        (report.held, report.quiet) = (sessionUpdates.held.count, sessionUpdatesQuiet)
        return report
    }
}

extension LocalReplyEndpoint {
    /// Same admission budget and fail-closed audit as an ambient request: `pushed(tool: "local-update")` with the
    /// target, or the action when there is none. The update's text is never logged or audited.
    func submitSessionUpdate(_ data: Data, from client: LocalReplyConnection) async {
        do {
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let request: LocalSessionUpdateRequest
            do { request = try JSONDecoder().decode(LocalSessionUpdateRequest.self, from: data) } catch {
                updateLogger.error("Local update decode failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.decodeFailure
            }
            let target = request.target ?? request.action.rawValue
            do { _ = try await audit.record(.pushed(tool: "local-update", target: target, bytes: data.count)) } catch {
                updateLogger.error("Local update audit failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.auditFailure
            }
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let report = await destination.sessionUpdate(request)
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            await respond(.update(report), to: client)
        } catch is CancellationError {
            retire(client.id)
        } catch {
            let reason = LocalReplyRefusal(error)
            guard !stopped, connections[client.id] != nil else { return retire(client.id) }
            await respond(.init(delivered: 0, error: reason.message, code: reason), to: client)
        }
    }
}
