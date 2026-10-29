import Foundation

/// `haild notify` over the owner-only local reply socket (#609): a local session's unsolicited update, quiet on, or
/// a status question. The speaking session must be a live target the registry lists, never free text. Any local
/// process of the owner may name any live target (sessions may phone in, #371), so the name says which session an
/// update is about, not which process sent it, and the per-session budget, quiet and media mode are cooperative
/// limits, not a security boundary. Exactly the keys the action uses; anything else is refused.
public struct LocalSessionUpdateRequest: Codable, Sendable, Equatable {
    public static let kind = "update"

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Holds first, then offers an action card to the host-decided exact recipient. Speech requires the
        /// separately negotiated device admission capability and an explicitly configured host renderer.
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
        case held, delivered, dropped, refused, status, notEnabled = "not_enabled"
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
    /// Cards are available independently of spoken admission. This is capability status, never hearing proof.
    public var speechUnavailable: String? = "attention_signal_missing"
    public var speechStatus: String?

    public init(outcome: Outcome, reason: String? = nil) { (self.outcome, self.reason) = (outcome, reason) }
}

extension WebSocketListener {
    /// `--session-updates` (#609): sessions may send updates. Off by default.
    func enableSessionUpdates() { sessionUpdates.policy.enabled = true }

    /// Applies the update policy to a local request (#609). The text is neither logged nor audited.
    public func sessionUpdate(_ request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        guard sessionUpdates.policy.enabled else { return LocalSessionUpdateReport(outcome: .notEnabled) }
        purgePrivateSessionUpdates()
        guard !stopped else { return updateReport(.refused, reason: "stopping") }
        switch request.action {
        case .status: return updateReport(.status)
        case .quietOn:
            sessionUpdatesQuiet = true
            sessionUpdateFence.quiet()
            return updateReport(.status)
        case .submit: return await sessionUpdate(carried: request)
        }
    }

    private func sessionUpdate(carried request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        let revision = SessionUpdatePrivacyScope.expectedRevision ?? replyHold.entryRevision
        guard !sessionUpdatesPrivate else { return updateReport(.dropped, reason: "private") }
        guard let target = request.target else { return updateReport(.refused, reason: "unknown_target") }
        let authority = await sessionUpdateAuthority(for: target)
        guard let listing = try? await host.registry.listing(),
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
        if revision != replyHold.entryRevision {
            return updateReport(.dropped, reason: "private")
        }
        authority?.generation.observePolicy()
        guard let authority, authority.isCurrent,
              authority.binding == listing.first(where: { $0.info.id == target })?.binding else {
            return updateReport(.refused, reason: "retired_authority")
        }
        guard !sessionUpdatesPrivate else { return updateReport(.dropped, reason: "private") }
        // Hold before delivery so a failed exact-peer hand-off cannot consume an update or spend its budget twice.
        var audience = updateAudience(for: target)
        (audience.lastActiveDevice, audience.listeningDevice) = (audience.target, nil)
        let decision = sessionUpdates.submit(update, audience: audience, now: now)
        guard case .held = decision else { return decided(decision) }
        sessionUpdateTaskAuthorities[update.id] = authority
        // Routine information waits for a real interaction/playback pause. Action cards may be delivered now;
        // neither path borrows a request reference or asks the uncorrelated reply router to choose a device.
        let deliverCard = update.priority == .action
        let delivered = deliverCard
            ? await drainSessionUpdates(.interaction, only: update.id).contains(update.id) : false
        purgePrivateSessionUpdates()
        if sessionUpdates.held.contains(where: { $0.id == update.id }) { return decided(decision) }
        return updateReport(delivered ? .delivered : .dropped, reason: delivered ? nil : "private")
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

    func updateReport(_ outcome: LocalSessionUpdateReport.Outcome, reason: String? = nil)
        -> LocalSessionUpdateReport {
        var report = LocalSessionUpdateReport(outcome: outcome, reason: reason)
        (report.held, report.quiet) = (sessionUpdates.held.count, sessionUpdatesQuiet)
        report.speechStatus = sessionUpdateFence.speechStatus
        report.speechUnavailable = report.speechStatus == "not_configured" ? "renderer_not_configured" : nil
        return report
    }
}
