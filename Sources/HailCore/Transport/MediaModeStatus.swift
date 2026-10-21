public import Foundation

/// The owner's spoken media mode (#551) as a host last reported it for this device's ambient stream (#612). While it
/// is on, RightyO hears only the owner naming the assistant, so replies stop; the station shows that instead of
/// leaving it looking broken. State only: the device cannot change the mode.
public struct MediaModeStatus: Equatable, Sendable {
    public let on: Bool
    /// Why it last changed: `voice` or `timeout`, or nil when the host did not say.
    public let reason: String?
    /// When an on mode turns itself off.
    public let expires: Date?

    public init(on: Bool, reason: String? = nil, expires: Date? = nil) {
        self.on = on
        self.reason = reason
        self.expires = on ? expires : nil
    }

    /// From a host's `media_mode` (Unix milliseconds for `expires`).
    public init(on: Bool, reason: String?, expiresMilliseconds: Int64?) {
        self.init(on: on, reason: reason,
                  expires: expiresMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) })
    }

    /// What the ambient card says while media mode is on, or nil when it is off or has already run out.
    public func detail(now: Date = Date(), timeStyle: Date.FormatStyle = .dateTime.hour().minute()) -> String? {
        guard on else { return nil }
        let ending = "Say the assistant's name and \u{201C}done watching\u{201D} to end it."
        guard let expires else { return "Only the assistant's name is heard. \(ending)" }
        guard expires > now else { return nil }
        return "Only the assistant's name is heard. \(ending) It ends by itself at \(expires.formatted(timeStyle))."
    }
}
