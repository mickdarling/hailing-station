public import Foundation
// The control command set and the diagnostic event vocabulary (#234) it carries stay together, so every
// bound a peer can send is visible in one file.
// swiftlint:disable file_length

/// A target as the host lists it (#8, #10).
public struct TargetInfo: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var name: String
    public var alive: Bool

    public init(id: String, kind: String, name: String, alive: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.alive = alive
    }
}

/// Bounds on control fields so free text from a peer or a host-side tool stays small (#7, #44).
public enum ControlLimits {
    public static let maxErrorMessage = 256
}

/// What each end says first. `versions` lists every protocol version it can speak and is never empty,
/// so negotiation can fail closed instead of guessing (#2 item 5, threat model B2 downgrade).
public struct HelloInfo: Codable, Sendable, Equatable {
    public var versions: [Int]
    public var capabilities: [String]
    public var deviceName: String
    /// The device's class only (#366): `phone`, `pad` or `mac` from `AmbientTakeOver.deviceKinds`, never its
    /// name. Optional, so an older peer's hello is unchanged; a value outside the vocabulary fails the hello.
    public var deviceKind: String?

    public init(versions: [Int], capabilities: [String], deviceName: String, deviceKind: String? = nil) {
        self.versions = versions
        self.capabilities = capabilities
        self.deviceName = deviceName
        self.deviceKind = AmbientTakeOver.deviceKind(deviceKind)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versions = try container.decode([Int].self, forKey: .versions)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .deviceKind)
        deviceKind = AmbientTakeOver.deviceKind(rawKind)
        // Strict: we control every client, so a kind outside the vocabulary is a bug, not a future value.
        guard rawKind == nil || deviceKind != nil else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath + [CodingKeys.deviceKind], debugDescription: "unknown device kind"
            )
            throw DecodingError.dataCorrupted(context)
        }
        guard !versions.isEmpty else {
            let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "no versions")
            throw DecodingError.dataCorrupted(context)
        }
    }

    private enum CodingKeys: String, CodingKey { case versions, capabilities, deviceName, deviceKind }
}

/// Closed set of error codes. Unknown strings decode to `.unknown` so a newer peer's code is kept, not lost.
public enum ErrorCode: Sendable, Equatable, Codable {
    case unauthorized, unknownTarget, notAllowed, lockdown, rateLimited, protocolVersion, malformed
    case unknown(String)

    private static let names: [String: ErrorCode] = [
        "unauthorized": .unauthorized, "unknown_target": .unknownTarget, "not_allowed": .notAllowed,
        "lockdown": .lockdown, "rate_limited": .rateLimited, "protocol_version": .protocolVersion,
        "malformed": .malformed
    ]

    public var rawValue: String {
        if case .unknown(let raw) = self { return raw }
        return Self.names.first { $0.value == self }?.key ?? "unknown"
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.names[raw] ?? .unknown(raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The control command set. Encoded as `{"command": "...", ...fields}` inside the frame payload.
public enum ControlPayload: Sendable, Equatable {
    case hello(HelloInfo)
    case listTargets
    case targets([TargetInfo])
    case select(targetID: String)
    case subscribe(targetID: String)
    case unsubscribe(targetID: String)
    /// Send one literal Escape key to the selected target. This is intentionally narrower than a
    /// generic remote-key command so the fast cancellation path cannot become arbitrary input.
    case escape(targetID: String)
    case ping(nonce: String)
    case pong(nonce: String)
    case error(code: ErrorCode, message: String)
    /// Device diagnostics (#234): enumerated events with bounded scalar fields, sent only to a host that
    /// advertises `DiagnosticLimits.capability`. They carry no audio or text and grant no authority.
    case diagnostic(events: [DiagnosticEvent])
    /// Host to device (#309): stop reply playback now and drop queued reply audio, sent only to a device that
    /// advertises `PlaybackStop.capability`. It carries nothing else and grants no authority.
    case stopPlayback
    /// Host to device (#366): this connection's new ambient stream took listening over from another device of
    /// kind `from` (an `AmbientTakeOver.deviceKinds` token, or nil when that device did not say). Sent only to a
    /// device that advertises `AmbientTakeOver.capability`. It carries nothing else and grants no authority.
    case ambientMovedHere(from: String?)
    /// Host to device (#318): the request this connection's ambient stream just handed to `targetID`, as heard,
    /// so the device can show the user's own words in the thread. Sent only to the device that spoke, before the
    /// request is typed, and only when it advertises `AmbientHeard.capability`. It grants no authority.
    case ambientHeard(targetID: String, text: String)
    /// Host to device (#398): a turn this connection's ambient stream heard but did not send to `targetID`, by the
    /// owner or by someone else, within the scope the device asked for with `overheardScope`. Sent only to the device
    /// that heard it, only when it advertises `AmbientOverheard.capability`. It grants no authority.
    /// `name` (#434) is the display name of the enrolled guest RightyO bound the turn to, only with speaker `other`
    /// and only to a device that advertises `AmbientOverheard.namesCapability`; nil means "someone".
    case ambientOverheard(targetID: String, text: String, speaker: String, name: String? = nil)
    /// Device to host (#398): which overheard turns this connection wants, one of `AmbientOverheard.scopes`. The host
    /// starts every connection at `off`. It grants no authority beyond choosing what the host may send back.
    case overheardScope(scope: String)
    /// Host to device (#404): mute or unmute this device's reply audio, as its own mute control does. Sent only to a
    /// device that advertises `ReplyMute.capability`. It carries nothing else and grants no authority.
    case setReplyMute(muted: Bool)
    /// Host to device (rightyo#164): whether RightyO recognises the owner's voice on this device's input, one of
    /// `OwnerVoice.states`. Sent only to the device whose stream it is, only when it advertises
    /// `OwnerVoice.capability`. It grants no authority and carries no name, score or audio detail.
    case ownerVoice(state: String)
    /// Device to host (rightyo#164): the kind of input route this device's ambient audio now comes from, one of the
    /// diagnostic `route` tokens (`usb_audio`, `car_audio`, ...), never a port name. Sent only to a host that
    /// advertises `AmbientInput.capability`, so speaker-ID results can be attributed to an input chain.
    case ambientInput(route: String)
    /// Host to device (#609): an unsolicited update from the local session named `session` (#371), with its
    /// `priority` (one of `SessionUpdateCard.priorities`), the short line `text` that is or will be spoken, and an
    /// optional `card` body shown, never spoken. `update` identifies it, so a device shows a resent update once. Sent
    /// only to a device that advertises `SessionUpdateCard.capability`. It grants no authority and selects nothing.
    case sessionUpdate(update: UUID, session: String, priority: String, text: String, card: String? = nil)

    /// Host to device (#612): whether the owner's spoken media mode (#551) is on for this device's ambient stream, why
    /// it last changed (one of `MediaMode.reasons`), and while on, when it turns itself off (Unix milliseconds). Sent
    /// only to a device that advertises `MediaMode.capability`. It shows state only and grants no authority.
    case mediaMode(on: Bool, reason: String? = nil, expires: Int64? = nil)
}

extension ControlPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, hello, targets, targetID = "target", nonce, code, message, events, from, text, speaker, scope
        case muted, name, state, route, update, session, priority, card, on, reason, expires
    }

    private enum Command: String, Codable {
        case hello, listTargets = "list_targets", targets, select, subscribe, unsubscribe, escape, ping, pong, error
        case diagnostic, stopPlayback = "stop_playback", ambientMovedHere = "ambient_moved_here"
        case ambientHeard = "ambient_heard", ambientOverheard = "ambient_overheard", overheardScope = "overheard_scope"
        case setReplyMute = "set_reply_mute", ownerVoice = "owner_voice", ambientInput = "ambient_input"
        case sessionUpdate = "session_update"
        case mediaMode = "media_mode"
    }

    // A closed wire enum is clearest as one exhaustive switch.
    // swiftlint:disable:next cyclomatic_complexity
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Command.self, forKey: .command) {
        case .hello: self = .hello(try container.decode(HelloInfo.self, forKey: .hello))
        case .listTargets: self = .listTargets
        case .targets: self = .targets(try container.decode([TargetInfo].self, forKey: .targets))
        case .select: self = .select(targetID: try container.decode(String.self, forKey: .targetID))
        case .subscribe: self = .subscribe(targetID: try container.decode(String.self, forKey: .targetID))
        case .unsubscribe: self = .unsubscribe(targetID: try container.decode(String.self, forKey: .targetID))
        case .escape: self = .escape(targetID: try container.decode(String.self, forKey: .targetID))
        case .ping: self = .ping(nonce: try container.decode(String.self, forKey: .nonce))
        case .pong: self = .pong(nonce: try container.decode(String.self, forKey: .nonce))
        case .error:
            let message = try container.decode(String.self, forKey: .message)
            guard message.count <= ControlLimits.maxErrorMessage else {
                let context = DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "message too long"
                )
                throw DecodingError.dataCorrupted(context)
            }
            self = .error(code: try container.decode(ErrorCode.self, forKey: .code), message: message)
        case .diagnostic:
            // Strict, unlike the other commands (#234): only `command` and `events`, so nothing rides along.
            try Self.requireOnly(["command", "events"], "diagnostic", decoder)
            let events = try container.decode([DiagnosticEvent].self, forKey: .events)
            try requireRange(events.count, in: 1...DiagnosticLimits.maxEventsPerBatch, "events", decoder)
            self = .diagnostic(events: events)
        case .stopPlayback:
            // Strict, like `diagnostic`: only `command`, so nothing rides along on a stop.
            try Self.requireOnly(["command"], "stop_playback", decoder)
            self = .stopPlayback
        case .ambientMovedHere: self = try Self.ambientMovedHere(from: decoder)
        case .ambientHeard: self = try Self.ambientHeard(from: decoder)
        case .ambientOverheard: self = try Self.ambientOverheard(from: decoder)
        case .overheardScope: self = try Self.overheardScope(from: decoder)
        case .setReplyMute: self = try Self.setReplyMute(from: decoder)
        case .ownerVoice: self = try Self.ownerVoice(from: decoder)
        case .ambientInput: self = try Self.ambientInput(from: decoder)
        case .sessionUpdate: self = try Self.sessionUpdate(from: decoder)
        case .mediaMode: self = try Self.mediaMode(from: decoder)
        }
    }

    /// Strict (#609): only `command`, `update`, a `session` name `SessionUpdateCard.session` accepts, a known
    /// `priority`, non-empty `text`, and an optional non-empty `card`, each text within the text payload's byte cap.
    private static func sessionUpdate(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "update", "session", "priority", "text", "card"], "session_update", decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let update = try container.decode(UUID.self, forKey: .update)
        let text = try container.decode(String.self, forKey: .text)
        try requireRange(text.utf8.count, in: 1...PayloadLimits.maxTextBytes, "text", decoder)
        // Present means a string: an explicit null is refused like any other wrong type.
        let card = container.contains(.card) ? try container.decode(String.self, forKey: .card) : nil
        if let card { try requireRange(card.utf8.count, in: 1...PayloadLimits.maxTextBytes, "card", decoder) }
        guard let session = SessionUpdateCard.session(try container.decode(String.self, forKey: .session)),
              let priority = SessionUpdateCard.priority(try container.decode(String.self, forKey: .priority)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid session_update session or priority"))
        }
        return .sessionUpdate(update: update, session: session, priority: priority, text: text, card: card)
    }

    /// Strict (#612): only `command`, the boolean `on`, an optional `reason` from `MediaMode.reasons` and, only while
    /// on, a positive `expires`.
    private static func mediaMode(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "on", "reason", "expires"], "media_mode", decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let on = try container.decode(Bool.self, forKey: .on)
        let raw = try container.decodeIfPresent(String.self, forKey: .reason)
        let expires = try container.decodeIfPresent(Int64.self, forKey: .expires)
        guard raw == nil || MediaMode.reason(raw) != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown media_mode reason"))
        }
        guard MediaMode.validExpiry(expires, on: on) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid media_mode expires"))
        }
        return .mediaMode(on: on, reason: MediaMode.reason(raw), expires: expires)
    }

    /// Strict (rightyo#164): only `command` and a `state` from `OwnerVoice.states`.
    private static func ownerVoice(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "state"], "owner_voice", decoder)
        guard let state = OwnerVoice.state(try decoder.container(keyedBy: CodingKeys.self).decode(
            String.self, forKey: .state
        )) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown owner_voice state"))
        }
        return .ownerVoice(state: state)
    }

    /// Strict (rightyo#164): only `command` and a `route` from `AmbientInput.routes`.
    private static func ambientInput(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "route"], "ambient_input", decoder)
        guard let route = AmbientInput.route(try decoder.container(keyedBy: CodingKeys.self).decode(
            String.self, forKey: .route
        )) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown ambient_input route"))
        }
        return .ambientInput(route: route)
    }

    /// Strict, like `stop_playback` (#366): only `command` and an optional class from the closed vocabulary.
    private static func ambientMovedHere(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "from"], "ambient_moved_here", decoder)
        let from = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .from)
        guard from == nil || AmbientTakeOver.deviceKind(from) != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown ambient_moved_here device"))
        }
        return .ambientMovedHere(from: from)
    }

    /// Strict, like `stop_playback` (#404): only `command` and the boolean `muted`.
    private static func setReplyMute(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "muted"], "set_reply_mute", decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        return .setReplyMute(muted: try container.decode(Bool.self, forKey: .muted))
    }

    /// Strict (#398): like `ambient_heard`, plus a `speaker` from `AmbientOverheard.speakers`, and (#434) an optional
    /// `name` that `AmbientOverheard.name` accepts, only with speaker `other`.
    private static func ambientOverheard(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "target", "text", "speaker", "name"], "ambient_overheard", decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        try requireRange(text.utf8.count, in: 1...PayloadLimits.maxTextBytes, "text", decoder)
        let target = try container.decode(String.self, forKey: .targetID)
        try requireRange(target.utf8.count, in: 1...PayloadLimits.maxTextBytes, "target", decoder)
        guard let speaker = AmbientOverheard.speaker(try container.decode(String.self, forKey: .speaker)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown ambient_overheard speaker"))
        }
        // Present means a string: an explicit null is refused like any other wrong type.
        let name = container.contains(.name) ? try container.decode(String.self, forKey: .name) : nil
        guard name.map({ AmbientOverheard.name($0) != nil && speaker == "other" }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid ambient_overheard name"))
        }
        return .ambientOverheard(targetID: target, text: text, speaker: speaker, name: name)
    }

    /// Strict (#398): only `command` and a `scope` from `AmbientOverheard.scopes`.
    private static func overheardScope(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "scope"], "overheard_scope", decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let scope = AmbientOverheard.scope(try container.decode(String.self, forKey: .scope)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown overheard_scope scope"))
        }
        return .overheardScope(scope: scope)
    }

    /// Strict (#318): only `command`, a non-empty `target`, and non-empty `text` within the text payload's byte cap.
    private static func ambientHeard(from decoder: any Decoder) throws -> ControlPayload {
        try requireOnly(["command", "target", "text"], "ambient_heard", decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        try requireRange(text.utf8.count, in: 1...PayloadLimits.maxTextBytes, "text", decoder)
        let target = try container.decode(String.self, forKey: .targetID)
        try requireRange(target.utf8.count, in: 1...PayloadLimits.maxTextBytes, "target", decoder)
        return .ambientHeard(targetID: target, text: text)
    }

    /// A closed-vocabulary token as matched, or an encoding error, so this type never writes a frame it would refuse.
    private static func closed(_ matched: String?, _ raw: String, _ encoder: any Encoder) throws -> String {
        guard let matched else {
            throw EncodingError.invalidValue(raw, .init(codingPath: encoder.codingPath,
                                                        debugDescription: "not in the closed vocabulary"))
        }
        return matched
    }

    /// Refuses any payload key outside `allowed`, so nothing rides along on a strict command.
    private static func requireOnly(_ allowed: [String], _ command: String, _ decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: DiagnosticCodingKey.self).allKeys.map(\.stringValue)
        guard keys.allSatisfy({ DiagnosticLimits.isOne(of: allowed, $0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown \(command) payload key"))
        }
    }

    // One exhaustive switch over the closed wire enum, like the decoder.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let info):
            try container.encode(Command.hello, forKey: .command)
            try container.encode(info, forKey: .hello)
        case .listTargets:
            try container.encode(Command.listTargets, forKey: .command)
        case .targets(let list):
            try container.encode(Command.targets, forKey: .command)
            try container.encode(list, forKey: .targets)
        case .select(let id):
            try container.encode(Command.select, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .subscribe(let id):
            try container.encode(Command.subscribe, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .unsubscribe(let id):
            try container.encode(Command.unsubscribe, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .escape(let id):
            try container.encode(Command.escape, forKey: .command)
            try container.encode(id, forKey: .targetID)
        case .ping(let nonce):
            try container.encode(Command.ping, forKey: .command)
            try container.encode(nonce, forKey: .nonce)
        case .pong(let nonce):
            try container.encode(Command.pong, forKey: .command)
            try container.encode(nonce, forKey: .nonce)
        case .error(let code, let message):
            try container.encode(Command.error, forKey: .command)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        case .diagnostic(let events):
            try container.encode(Command.diagnostic, forKey: .command)
            try container.encode(events, forKey: .events)
        case .stopPlayback: try container.encode(Command.stopPlayback, forKey: .command)
        case .ambientMovedHere(let from):
            try container.encode(Command.ambientMovedHere, forKey: .command)
            try container.encodeIfPresent(AmbientTakeOver.deviceKind(from), forKey: .from)
        case .ambientHeard(let id, let text):
            try container.encode(Command.ambientHeard, forKey: .command)
            try container.encode(id, forKey: .targetID)
            try container.encode(text, forKey: .text)
        case .ambientOverheard(let id, let text, let speaker, let name):
            try container.encode(Command.ambientOverheard, forKey: .command)
            try container.encode(id, forKey: .targetID)
            try container.encode(text, forKey: .text)
            try container.encode(try Self.closed(AmbientOverheard.speaker(speaker), speaker, encoder), forKey: .speaker)
            if let name {
                let valid = speaker == "other" ? AmbientOverheard.name(name) : nil
                try container.encode(try Self.closed(valid, name, encoder), forKey: .name)
            }
        case .overheardScope(let scope):
            try container.encode(Command.overheardScope, forKey: .command)
            try container.encode(try Self.closed(AmbientOverheard.scope(scope), scope, encoder), forKey: .scope)
        case .setReplyMute(let muted):
            try container.encode(Command.setReplyMute, forKey: .command)
            try container.encode(muted, forKey: .muted)
        case .ownerVoice(let state):
            try container.encode(Command.ownerVoice, forKey: .command)
            try container.encode(try Self.closed(OwnerVoice.state(state), state, encoder), forKey: .state)
        case .ambientInput(let route):
            try container.encode(Command.ambientInput, forKey: .command)
            try container.encode(try Self.closed(AmbientInput.route(route), route, encoder), forKey: .route)
        case .sessionUpdate(let update, let session, let priority, let text, let card):
            try container.encode(Command.sessionUpdate, forKey: .command)
            try container.encode(update, forKey: .update)
            try container.encode(try Self.closed(SessionUpdateCard.session(session), session, encoder),
                                 forKey: .session)
            try container.encode(try Self.closed(SessionUpdateCard.priority(priority), priority, encoder),
                                 forKey: .priority)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(card, forKey: .card)
        case .mediaMode(let on, let reason, let expires):
            try container.encode(Command.mediaMode, forKey: .command)
            try container.encode(on, forKey: .on)
            if let reason {
                try container.encode(try Self.closed(MediaMode.reason(reason), reason, encoder), forKey: .reason)
            }
            guard MediaMode.validExpiry(expires, on: on) else {
                throw EncodingError.invalidValue(expires as Any, .init(codingPath: encoder.codingPath,
                                                                      debugDescription: "invalid media_mode expires"))
            }
            try container.encodeIfPresent(expires, forKey: .expires)
        }
    }
}

/// Session update cards (#609): a local session's unsolicited update, shown in the thread with the session that sent
/// it (#371). The device advertises `capability` in its `hello`; a host never sends `session_update` to a device
/// without it, because an older device refuses an unknown command as malformed.
public enum SessionUpdateCard {
    public static let capability = "session_update"
    public static let priorities = ["info", "action"]

    /// `value` when it is exactly one of `priorities`, else nil.
    public static func priority(_ value: String?) -> String? {
        value.flatMap { value in priorities.first { DiagnosticLimits.sameBytes($0, value) } }
    }

    /// `value` when it is a name a device may show as the speaker, by the guest display-name rule
    /// (`AmbientOverheard.name`): 1 to 64 printable scalars, no surrounding whitespace. Else nil.
    public static func session(_ value: String?) -> String? { AmbientOverheard.name(value) }
}

/// Reply playback stop (#309). The device advertises the capability in its `hello`; a host never sends
/// `stop_playback` to a device without it, because an older device refuses an unknown command as malformed.
public enum PlaybackStop {
    public static let capability = "stop_playback"
}

/// Reply mute (#404): the owner's spoken "mute" or "unmute", carried out on the device that heard it. The device
/// advertises the capability in its `hello`; a host never sends `set_reply_mute` to a device without it, because an
/// older device refuses an unknown command as malformed. `muted` is the device's own reply mute: later reply audio
/// plays silently while its text still shows, so a replay still works, until the device or the host unmutes it.
/// The host sends `stop_playback` first when the reply now playing should end at once.
public enum ReplyMute {
    public static let capability = "reply_mute"
}

/// Owner voice status (rightyo#164): RightyO tells the host when the enrolled owner's voice is not recognised on the
/// current input (a new mic, a USB interface, CarPlay), so the device can say so instead of owner-only features
/// failing silently, and when it is recognised again. The device advertises `capability` in its `hello`; a host
/// never sends `owner_voice` to a device without it, because an older device refuses an unknown command.
public enum OwnerVoice {
    public static let capability = "owner_voice_status"
    public static let states = ["recognized", "unrecognized"]

    /// `value` when it is exactly one of `states`, else nil.
    public static func state(_ value: String?) -> String? {
        value.flatMap { value in states.first { DiagnosticLimits.sameBytes($0, value) } }
    }
}

/// Ambient input route (rightyo#164): the device names the kind of input its ambient audio comes from, so the host can
/// log it with each speaker-ID session and a voiceprint that fails on one input chain can be attributed. Only a
/// route kind from the diagnostic `route` vocabulary is sent, never a port or device name. The host advertises
/// `capability` in its `hello`; a device never sends `ambient_input` to a host without it.
public enum AmbientInput {
    public static let capability = "ambient_input_route"
    public static var routes: [String] { DiagnosticField.route.tokens }

    /// `value` when it is exactly one of `routes`, else nil.
    public static func route(_ value: String?) -> String? {
        value.flatMap { value in routes.first { DiagnosticLimits.sameBytes($0, value) } }
    }
}

/// Media mode state (#612): the owner's spoken media mode (#551) is host-side, so without this a device only notices
/// that replies stopped. A host tells the device whose ambient stream it is when the mode changes. The device
/// advertises `capability` in its `hello`; a host never sends `media_mode` to a device without it, because an older
/// device refuses an unknown command. `reason` says why it last changed: `voice` (the owner said so) or `timeout`
/// (it turned itself off). `expires` is when an on mode turns itself off, in Unix milliseconds like a frame's `ts`.
public enum MediaMode {
    public static let capability = "media_mode"
    public static let reasons = ["voice", "timeout"]

    /// `value` when it is exactly one of `reasons`, else nil.
    public static func reason(_ value: String?) -> String? {
        value.flatMap { value in reasons.first { DiagnosticLimits.sameBytes($0, value) } }
    }

    /// An expiry is optional, positive, and only meaningful while the mode is on.
    static func validExpiry(_ expires: Int64?, on: Bool) -> Bool {
        guard let expires else { return true }
        return on && expires > 0
    }
}

/// The user's own ambient request, shown in the thread (#318). The device advertises the capability in its `hello`;
/// a host never sends `ambient_heard` to a device without it, because an older device refuses an unknown command.
public enum AmbientHeard {
    public static let capability = "ambient_heard"
}

/// Overheard remarks in the thread (#398): turns the ambient stream heard but did not send. Both sides advertise
/// `capability` in their `hello`. A device sends `overheard_scope` only to a host that advertised it (an older host
/// refuses the command), and a host sends `ambient_overheard` only to a device that advertised it. The host starts every
/// connection at `off`, so nothing is sent until the device asks.
public enum AmbientOverheard {
    public static let capability = "ambient_overheard"
    public static let scopes = ["off", "owner", "everyone"]
    public static let speakers = ["owner", "other"]
    /// A device that can show a known guest's name (#434) advertises this as well; a host sends `name` only to it,
    /// because an older device refuses the unknown key.
    public static let namesCapability = "ambient_overheard_names"
    /// RightyO's own display-name bound (rightyo enroll: 1 to 64 printable characters), in Unicode scalars.
    public static let maxNameScalars = 64

    /// `value` when it is a display name a device may show: 1 to `maxNameScalars` scalars, no control, format or
    /// line-breaking characters, and no leading or trailing whitespace. Else nil.
    public static func name(_ value: String?) -> String? {
        guard let value, (1...maxNameScalars).contains(value.unicodeScalars.count),
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.unicodeScalars.allSatisfy({ scalar in
                  ![.control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse]
                      .contains(scalar.properties.generalCategory)
              }) else { return nil }
        return value
    }

    /// `value` when it is exactly one of `scopes`, else nil.
    public static func scope(_ value: String?) -> String? {
        value.flatMap { value in scopes.first { DiagnosticLimits.sameBytes($0, value) } }
    }

    /// `value` when it is exactly one of `speakers`, else nil.
    public static func speaker(_ value: String?) -> String? {
        value.flatMap { value in speakers.first { DiagnosticLimits.sameBytes($0, value) } }
    }
}

/// Ambient take-over (#366): the most recent device to start ambient listening on a host takes it over. The
/// host ends the previous device's stream and answers that device's next segment with a `not_allowed` error
/// whose message starts with `movedPrefix`; the new device, if it advertises `capability`, is sent
/// `ambient_moved_here`. A device is named only by its class, from `deviceKinds`.
public enum AmbientTakeOver {
    public static let capability = "ambient_takeover"
    public static let deviceKinds = ["phone", "pad", "mac"]
    public static let movedPrefix = "ambient moved"

    /// `value` when it is exactly one of `deviceKinds`, else nil.
    public static func deviceKind(_ value: String?) -> String? {
        value.flatMap { value in deviceKinds.first { DiagnosticLimits.sameBytes($0, value) } }
    }

    /// The previous device's error message: `ambient moved to pad`, or `ambient moved to another device` when the
    /// new device did not say its class.
    public static func movedMessage(to kind: String?) -> String {
        "\(movedPrefix) to \(deviceKind(kind) ?? "another device")"
    }

    /// Whether an error `message` is a take-over notice and, if it is, the new device's class (nil if unsaid).
    public static func moved(_ message: String) -> (moved: Bool, to: String?) {
        let lead = movedPrefix + " to "
        guard message.hasPrefix(lead) else { return (false, nil) }
        return (true, deviceKind(String(message.dropFirst(lead.count))))
    }
}

/// Picks the protocol version a session runs at: the highest version both ends list (#2 item 5).
public enum VersionNegotiation {
    /// Every version this build can speak, newest first. Grows when `ProtocolVersion.current` bumps (#33).
    public static let supported: [Int] = [ProtocolVersion.current]

    /// Returns `nil` when the sets are disjoint or `offered` is empty. Callers must then send
    /// `.error(code: .protocolVersion, ...)` and close; never fall back to `ProtocolVersion.current`.
    public static func choose(offered: [Int], supported: [Int] = supported) -> Int? {
        Set(offered).intersection(supported).max()
    }
}

/// Bounds on device diagnostics (#234). A batch is small and every value is a scalar: an integer, a boolean,
/// a version number, or a token from its field's closed vocabulary. The log's readers include AI agents, so
/// nothing a peer chooses freely, not even a short phrase, can reach it through this channel.
public enum DiagnosticLimits {
    /// The host capability that admits `diagnostic` frames. A host without it never receives one.
    public static let capability = "device_diagnostics"
    /// A host whose `code` vocabulary includes `stream_abandoned` (#469). An older host decodes an unknown token as
    /// a malformed frame and closes the connection, so a device sends that token only to a host advertising this,
    /// and `other` otherwise.
    public static let streamAbandonedCapability = "device_diagnostics_stream_abandoned"
    public static let maxEventsPerBatch = 32
    public static let integers: ClosedRange<Int64> = -2_147_483_648...2_147_483_647
    /// One to four dot-separated groups of one to six digits, as in `0.1.84` or `26.0.1`.
    public static let versionPattern = "^[0-9]{1,6}([.][0-9]{1,6}){0,3}$"

    /// Checked on UTF-8 bytes against ASCII ranges, never on Characters or scalars: a digit followed by
    /// invisible tag characters or combining marks is one Character but is not a version.
    public static func isVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var groups = 0, run = 0
        for byte in bytes {
            if (0x30...0x39).contains(byte) {
                run += 1
                guard run <= 6 else { return false }
            } else if byte == 0x2E, run > 0 {
                groups += 1
                run = 0
            } else {
                return false
            }
        }
        return run > 0 && groups <= 3
    }

    /// Byte-for-byte equality of the UTF-8 forms. Swift's `==` on strings is canonical equivalence, which
    /// is not what a closed ASCII vocabulary means.
    public static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Whether `value`'s bytes equal one of `allowed` exactly.
    static func isOne(of allowed: [String], _ value: String) -> Bool {
        allowed.contains { sameBytes($0, value) }
    }
}

/// The closed set of diagnostic events. An unknown name fails decoding; adding one needs a new capability.
public enum DiagnosticEventName: String, Codable, Sendable, CaseIterable {
    case appInfo = "app_info"
    case connectionState = "connection_state"
    case connectionError = "connection_error"
    case ambientStart = "ambient_start"
    case ambientStop = "ambient_stop"
    case routeChange = "route_change"
    case interruptionBegin = "interruption_begin"
    case interruptionEnd = "interruption_end"
    case appBackground = "app_background"
    case appForeground = "app_foreground"
    case hostRefusal = "host_refusal"
    case captureState = "capture_state"
    case captureError = "capture_error"
    case replyPlaybackStart = "reply_playback_start"
    case replyPlaybackEnd = "reply_playback_end"
    case replyPlaybackError = "reply_playback_error"
    case echoGuard = "echo_guard"
    case eventsDropped = "events_dropped"
}

/// The closed set of field keys, each with one fixed value kind. Token fields accept only their own
/// vocabulary; anything a device can't map exactly is sent as `other`.
public enum DiagnosticField: String, Codable, Sendable, CaseIterable, Comparable {
    case reason, state, code, domain, route, device
    case app, build, os
    case error, attempt, count, ms
    case on

    public enum Kind: Sendable { case token, version, integer, boolean }

    public var kind: Kind {
        switch self {
        case .reason, .state, .code, .domain, .route, .device: .token
        case .app, .build, .os: .version
        case .error, .attempt, .count, .ms: .integer
        case .on: .boolean
        }
    }

    /// The vocabulary of a token field, empty for every other kind.
    public var tokens: [String] { DiagnosticVocabulary.tokens[self] ?? [] }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Every value a token field may take (#234). Each list ends in `other`.
public enum DiagnosticVocabulary {
    static let tokens: [DiagnosticField: [String]] = [
        .reason: [
            // AVAudioSession route-change reasons
            "unknown", "new_device_available", "old_device_unavailable", "category_change", "override",
            "wake_from_sleep", "no_suitable_route", "route_configuration_change",
            // AVAudioSession interruption reasons
            "default", "app_was_suspended", "built_in_mic_muted", "scene_was_backgrounded", "route_disconnected",
            // why ambient listening stopped
            "user", "permission_denied", "binding_changed", "background", "start_failed", "capture_ended",
            "system_interruption", "host_refused", "send_failed", "other"
        ],
        .state: [
            "disconnected", "connecting", "negotiating", "ready", "reconnecting", "failed",
            "ended_by_system", "tap_to_talk_start", "tap_to_talk_end", "other"
        ],
        .code: [
            // host ErrorCode names
            "unauthorized", "unknown_target", "not_allowed", "lockdown", "rate_limited", "protocol_version",
            "malformed",
            // dropped-event sources
            "host_rate_limit", "app_buffer",
            // reply playback and capture failures
            "playback_failed", "resume_failed", "replay_failed", "format_unplayable", "conflicting_segment",
            // a reply stream ended because its terminal marker never came (#469)
            "stream_abandoned",
            "media_services_reset", "other"
        ],
        .domain: ["avfoundation", "coreaudio", "network", "posix", "other"],
        .route: [
            "none", "built_in_mic", "built_in_speaker", "built_in_receiver", "headphones", "headset_mic",
            "line_in", "line_out", "bluetooth_a2dp", "bluetooth_hfp", "bluetooth_le", "airplay", "hdmi",
            "car_audio", "usb_audio", "other"
        ],
        .device: ["phone", "pad", "mac", "other"]
    ]
}

public enum DiagnosticValue: Sendable, Equatable {
    /// A token-field vocabulary entry, or a version-field number.
    case token(String)
    case integer(Int64)
    case boolean(Bool)

    func isValid(for field: DiagnosticField) -> Bool {
        switch (self, field.kind) {
        case (.token(let value), .token): DiagnosticLimits.isOne(of: field.tokens, value)
        case (.token(let value), .version): DiagnosticLimits.isVersion(value)
        case (.integer(let value), .integer): DiagnosticLimits.integers.contains(value)
        case (.boolean, .boolean): true
        default: false
        }
    }
}

public struct DiagnosticEventInvalid: Error, Equatable, Sendable {
    public let field: DiagnosticField?
}

/// One diagnostic event. Only the validating initializer and the strict decoder can produce one, so an
/// event in hand always has a known name, known field keys, the right kind per key and bounded values.
public struct DiagnosticEvent: Sendable, Equatable {
    /// Milliseconds since 1970 on the device's clock.
    public let timestamp: Int64
    public let name: DiagnosticEventName
    public let fields: [DiagnosticField: DiagnosticValue]

    public init(
        _ name: DiagnosticEventName, timestamp: Int64, fields: [DiagnosticField: DiagnosticValue] = [:]
    ) throws {
        guard timestamp >= 0 else { throw DiagnosticEventInvalid(field: nil) }
        for (field, value) in fields where !value.isValid(for: field) {
            throw DiagnosticEventInvalid(field: field)
        }
        self.timestamp = timestamp
        self.name = name
        self.fields = fields
    }
}

extension DiagnosticEvent: Codable {
    typealias Key = DiagnosticCodingKey

    /// Unknown keys are refused here, unlike the rest of the protocol: free data must not ride along.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.allSatisfy({ DiagnosticLimits.isOne(of: ["ts", "name", "fields"], $0.stringValue) })
        else {
            throw Self.corrupt(decoder, "unknown diagnostic event key")
        }
        let timestamp = try container.decode(Int64.self, forKey: Key(stringValue: "ts"))
        let rawName = try container.decode(String.self, forKey: Key(stringValue: "name"))
        guard let name = DiagnosticEventName.allCases.first(where: { DiagnosticLimits.sameBytes($0.rawValue, rawName) })
        else { throw Self.corrupt(decoder, "unknown diagnostic event name") }
        var fields: [DiagnosticField: DiagnosticValue] = [:]
        if container.contains(Key(stringValue: "fields")) {
            let values = try container.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "fields"))
            for key in values.allKeys {
                guard let field = DiagnosticField.allCases.first(where: {
                    DiagnosticLimits.sameBytes($0.rawValue, key.stringValue)
                }) else {
                    throw Self.corrupt(decoder, "unknown diagnostic field")
                }
                switch field.kind {
                case .token, .version: fields[field] = .token(try values.decode(String.self, forKey: key))
                case .integer: fields[field] = .integer(try values.decode(Int64.self, forKey: key))
                case .boolean: fields[field] = .boolean(try values.decode(Bool.self, forKey: key))
                }
            }
        }
        do {
            try self.init(name, timestamp: timestamp, fields: fields)
        } catch {
            throw Self.corrupt(decoder, "diagnostic value out of bounds")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(timestamp, forKey: Key(stringValue: "ts"))
        try container.encode(name, forKey: Key(stringValue: "name"))
        var values = container.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "fields"))
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            let key = Key(stringValue: field.rawValue)
            switch value {
            case .token(let token): try values.encode(token, forKey: key)
            case .integer(let number): try values.encode(number, forKey: key)
            case .boolean(let flag): try values.encode(flag, forKey: key)
            }
        }
    }

    private static func corrupt(_ decoder: any Decoder, _ reason: String) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: reason))
    }
}

extension Schema {
    /// Strict where the rest of the schema is tolerant (#234): unknown event and field keys are refused.
    static let diagnosticEvents: JSONValue = .object([
        "type": .string("array"), "minItems": .integer(1),
        "maxItems": .integer(Int64(DiagnosticLimits.maxEventsPerBatch)),
        "items": .object([
            "type": .string("object"), "required": .array([.string("ts"), .string("name")]),
            "additionalProperties": .bool(false),
            "properties": .object([
                "ts": .object(["type": .string("integer"), "minimum": .integer(0)]),
                "name": .object(["enum": .array(DiagnosticEventName.allCases.map { .string($0.rawValue) })]),
                "fields": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object(Dictionary(uniqueKeysWithValues: DiagnosticField.allCases.map {
                        ($0.rawValue, diagnosticValue($0))
                    }))
                ])
            ])
        ])
    ])

    /// A `diagnostic` payload carries `command` and `events` and nothing else.
    static let diagnosticPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("diagnostic")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object(["command": .object([:]), "events": .object([:])])
        ])
    ])

    /// `ambient_moved_here` carries `command` and, optionally, a device-class `from` (#366).
    static let ambientMovedHerePayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("ambient_moved_here")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object(["command": .object([:]), "from": .object([:])])
        ])
    ])

    /// `ambient_heard` carries `command`, `target` and `text` and nothing else (#318). The `text` limits live here, not
    /// in the shared control properties, so no other command's extension field named `text` is constrained.
    static let ambientHeardPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("ambient_heard")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]), "target": .object([:]),
                "text": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(PayloadLimits.maxTextBytes))
                ])
            ])
        ])
    ])

    /// `ambient_overheard` carries `command`, `target`, `text`, `speaker` and an optional `name` (#434), nothing else.
    static let ambientOverheardPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("ambient_overheard")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]),
                "target": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(PayloadLimits.maxTextBytes))
                ]),
                "text": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(PayloadLimits.maxTextBytes))
                ]),
                "speaker": .object(["enum": .array(AmbientOverheard.speakers.map(JSONValue.string))]),
                // The decoder is stricter: printable only, untrimmed refused, and only with speaker `other` (#434).
                "name": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(AmbientOverheard.maxNameScalars))
                ])
            ])
        ])
    ])

    /// `overheard_scope` carries `command` and `scope` and nothing else (#398).
    static let overheardScopePayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("overheard_scope")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]),
                "scope": .object(["enum": .array(AmbientOverheard.scopes.map(JSONValue.string))])
            ])
        ])
    ])

    /// `set_reply_mute` carries `command` and a boolean `muted` and nothing else (#404).
    static let setReplyMutePayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("set_reply_mute")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object(["command": .object([:]), "muted": .object(["type": .string("boolean")])])
        ])
    ])

    /// `media_mode` carries `command`, a boolean `on`, an optional known `reason` and an optional positive integer
    /// `expires`, and nothing else (#612). That `expires` comes only with `on: true` is checked by the decoder.
    static let mediaModePayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("media_mode")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]), "on": .object(["type": .string("boolean")]),
                "reason": .object(["enum": .array(MediaMode.reasons.map(JSONValue.string))]),
                "expires": .object(["type": .string("integer"), "minimum": .integer(1)])
            ])
        ])
    ])

    /// `owner_voice` carries `command` and a known `state` and nothing else (rightyo#164).
    static let ownerVoicePayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("owner_voice")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]), "state": .object(["enum": .array(OwnerVoice.states.map(JSONValue.string))])
            ])
        ])
    ])

    /// `ambient_input` carries `command` and a known `route` and nothing else (rightyo#164).
    static let ambientInputPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("ambient_input")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]), "route": .object(["enum": .array(AmbientInput.routes.map(JSONValue.string))])
            ])
        ])
    ])

    /// `session_update` carries `command`, `update`, `session`, `priority`, `text` and an optional `card` (#609).
    static let sessionUpdatePayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("session_update")])])]),
        "then": .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([:]),
                "update": .object(["type": .string("string"), "minLength": .integer(1)]),
                // The decoder is stricter: printable only and untrimmed refused, as for a guest's name.
                "session": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(AmbientOverheard.maxNameScalars))
                ]),
                "priority": .object(["enum": .array(SessionUpdateCard.priorities.map(JSONValue.string))]),
                "text": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(PayloadLimits.maxTextBytes))
                ]),
                "card": .object([
                    "type": .string("string"), "minLength": .integer(1),
                    "maxLength": .integer(Int64(PayloadLimits.maxTextBytes))
                ])
            ])
        ])
    ])

    /// `stop_playback` carries only `command` (#309).
    static let stopPlaybackPayloadRule: JSONValue = .object([
        "if": .object(["properties": .object(["command": .object(["const": .string("stop_playback")])])]),
        "then": .object(["additionalProperties": .bool(false), "properties": .object(["command": .object([:])])])
    ])

    private static func diagnosticValue(_ field: DiagnosticField) -> JSONValue {
        switch field.kind {
        case .token:
            .object(["enum": .array(field.tokens.map(JSONValue.string))])
        case .version:
            .object([
                "type": .string("string"), "minLength": .integer(1), "maxLength": .integer(27),
                "pattern": .string(DiagnosticLimits.versionPattern)
            ])
        case .integer:
            .object([
                "type": .string("integer"), "minimum": .integer(DiagnosticLimits.integers.lowerBound),
                "maximum": .integer(DiagnosticLimits.integers.upperBound)
            ])
        case .boolean: .object(["type": .string("boolean")])
        }
    }
}

/// Any string key, so the diagnostic decoders can see and refuse keys they don't know.
struct DiagnosticCodingKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}
