import Foundation
import OSLog

private let updateLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "local-update")

/// `haild notify` over the owner-only local reply socket (#609): a local session's unsolicited update, quiet on, or
/// a status question. The speaking session must be a live target the registry lists, never free text. Any local
/// process of the owner may name any live target (sessions may phone in, #371), so the name says which session an
/// update is about, not which process sent it, and the per-session budget, quiet and media mode are cooperative
/// limits, not a security boundary. Exactly the keys the action uses; anything else is refused.
public struct LocalSessionUpdateRequest: Codable, Sendable, Equatable {
    public static let kind = "update"

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Holds the update by the policy. Speaking now (an `action` on a listening device, and #605's announce)
        /// waits for haild to deliver to the device it decided on itself; until then nothing is spoken from here.
        case submit
        /// Turns do-not-disturb on until haild restarts. A session may only turn it on: turning it off is the user's
        /// own control, not something a session can do over this socket.
        case quietOn = "quiet_on"
        case status

        var carriesUpdate: Bool { self == .submit }
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
        /// `held`: kept for a natural pause, "any updates?", or the next interaction. `status`: a status or quiet
        /// answer. `not_enabled`: haild runs without `--session-updates`.
        case held, refused, status, notEnabled = "not_enabled"
    }

    public var outcome: Outcome
    /// For `refused`: `disabled`, `rate_limited`, `full`, `expired`, `unknown_target`, `invalid` or `stopping`.
    public var reason: String?
    /// Whole seconds until the session may send again, for `rate_limited`.
    public var retryAfter: Int?
    /// A held `action` update with a device to tell: the caller may raise its own push notification too.
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
        case .quietOn:
            sessionUpdatesQuiet = true
            return updateReport(.status)
        case .submit: return await sessionUpdate(carried: request)
        }
    }

    private func sessionUpdate(carried request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        guard let target = request.target, let listing = try? await host.registry.listing(),
              listing.contains(where: { $0.info.id == target && $0.info.alive }) else {
            return updateReport(.refused, reason: "unknown_target")
        }
        let now = ContinuousClock.now
        guard !stopped, let update = SessionUpdate(
            session: target, priority: request.priority ?? .info, spoken: request.text ?? "", card: request.card,
            submitted: now
        ) else {
            return updateReport(.refused, reason: stopped ? "stopping" : "invalid")
        }
        // Nothing is spoken from here: the reply path's request-less routing may pick another device than the
        // listening one the policy would approve (#605, #551). Until haild delivers to the decided device itself, the
        // listening device is offered only as the target to push to, so the policy holds the update, and spends the
        // session's budget only once it is held (a full queue costs nothing).
        var audience = updateAudience(for: target)
        (audience.lastActiveDevice, audience.listeningDevice) = (audience.target, nil)
        return decided(sessionUpdates.submit(update, audience: audience, now: now))
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
        // Not reached: no listening device is offered (`sessionUpdate(carried:)`).
        case .speak: return updateReport(.held)
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
    /// action token. Neither the target nor the update's text is logged or audited.
    func submitSessionUpdate(_ data: Data, from client: LocalReplyConnection) async {
        do {
            try Task.checkCancellation()
            guard !stopped, connections[client.id] != nil else { throw CancellationError() }
            let request: LocalSessionUpdateRequest
            do { request = try JSONDecoder().decode(LocalSessionUpdateRequest.self, from: data) } catch {
                updateLogger.error("Local update decode failed: \(String(reflecting: error), privacy: .private)")
                throw LocalReplyRefusal.decodeFailure
            }
            // The action token, never the caller's target text: an unknown target is refused only after this record.
            let action = request.action.rawValue
            do { _ = try await audit.record(.pushed(tool: "local-update", target: action, bytes: data.count)) } catch {
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
