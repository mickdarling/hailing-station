public import Foundation

/// The owner's rubber-duck mode (#735) as a host last reported it for this device's ambient stream. While it is on,
/// RightyO decides nothing and nothing is sent, so the station says so instead of leaving a long silence looking
/// broken (H-4). The device can end it (`end_duck_mode`, on a host that offers it), never start it.
public struct DuckModeStatus: Equatable, Sendable {
    /// How long the card says how duck mode ended, after the host said so.
    public static let endedNoteDuration: TimeInterval = 10 * 60

    public let on: Bool
    /// Why it last changed: `voice`, `timeout` or `device`, or nil when the host did not say.
    public let reason: String?
    /// When an on mode turns itself off.
    public let expires: Date?
    /// When this device was told, so the end note fades after `endedNoteDuration`.
    public let changed: Date

    public init(on: Bool, reason: String? = nil, expires: Date? = nil, changed: Date = Date()) {
        self.on = on
        self.reason = reason
        self.expires = on ? expires : nil
        self.changed = changed
    }

    /// From a host's `duck_mode` (Unix milliseconds for `expires`).
    public init(on: Bool, reason: String?, expiresMilliseconds: Int64?, changed: Date = Date()) {
        self.init(on: on, reason: reason,
                  expires: expiresMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) },
                  changed: changed)
    }

    /// Whether it is on at `now`: an on mode past its expiry counts as off, even before the host says so.
    public func isOn(now: Date = Date()) -> Bool {
        guard on else { return false }
        guard let expires else { return true }
        return expires > now
    }

    /// What the ambient card says while duck mode is on, or nil when it is off or has already run out.
    public func detail(now: Date = Date(), timeStyle: Date.FormatStyle = .dateTime.hour().minute()) -> String? {
        guard isOn(now: now) else { return nil }
        let base = "Thinking out loud. Say the assistant's name and \u{201C}done thinking\u{201D} to end it."
        guard let expires else { return base }
        return "\(base) It ends by itself at \(expires.formatted(timeStyle))."
    }

    /// How duck mode ended, for `endedNoteDuration` after the host said so; nil while on or after that. An on mode
    /// past its expiry, whose "off" has not arrived yet, reads as having ended by itself.
    public func endedDetail(now: Date = Date()) -> String? {
        if on {
            guard let expires, expires <= now, now < expires + Self.endedNoteDuration else { return nil }
            return Self.ended(reason: "timeout")
        }
        guard now < changed + Self.endedNoteDuration else { return nil }
        return Self.ended(reason: reason)
    }

    /// The end note for a host's `reason`. A reason this build does not know (a later host's) reads as plain "ended".
    static func ended(reason: String?) -> String {
        switch reason {
        case "voice": "Duck mode ended when you said so."
        // Also an older RightyO child that could not keep duck mode (#735): an `unsupported` reason is Mick's to add.
        case "timeout": "Duck mode ended by itself."
        case "device": "Duck mode ended from this device."
        default: "Duck mode ended."
        }
    }
}
