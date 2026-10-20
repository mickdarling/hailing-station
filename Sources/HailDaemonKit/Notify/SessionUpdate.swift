public import Foundation

/// How much a session's unsolicited update (#609) wants the user's attention. Silence is the default for routine
/// progress: a session sends one only for finished work, a needed decision, or a failure.
public enum SessionUpdatePriority: String, Codable, Sendable, CaseIterable {
    /// Worth knowing, not urgent: held for a natural pause, an "any updates?", or the next interaction.
    case info
    /// Needs the user: spoken now on a listening device, otherwise held and pushed.
    case action
}

/// One update a local session asks to give the user without a pending request (#609). The session name is what the
/// device shows as the speaker (#371): a target id or its display name, never anything more sensitive.
public struct SessionUpdate: Sendable, Equatable, Identifiable {
    public typealias Instant = ContinuousClock.Instant

    public static let maxSessionBytes = 64
    public static let maxSpokenBytes = 280
    public static let maxCardBytes = 4 * 1024

    public let id: UUID
    public let session: String
    public let priority: SessionUpdatePriority
    /// The short line spoken aloud.
    public let spoken: String
    /// Optional detail for the update card (links, PR numbers); shown, never spoken.
    public let card: String?
    public let submitted: Instant

    /// Nil when the session or spoken line is empty after trimming, or any field is over its limit.
    public init?(
        id: UUID = UUID(), session: String, priority: SessionUpdatePriority, spoken: String, card: String? = nil,
        submitted: Instant
    ) {
        let session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let card = card?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, session.utf8.count <= Self.maxSessionBytes,
              !spoken.isEmpty, spoken.utf8.count <= Self.maxSpokenBytes,
              (card?.utf8.count ?? 0) <= Self.maxCardBytes else { return nil }
        (self.id, self.session, self.priority, self.spoken) = (id, session, priority, spoken)
        (self.card, self.submitted) = (card?.isEmpty == false ? card : nil, submitted)
    }
}

/// The host's view of the user's devices when an update arrives or a drain is offered. The caller fills it from
/// live state; the policy never looks anything up itself.
public struct SessionUpdateAudience: Sendable, Equatable {
    /// The connection that owns the live ambient session, if one is listening.
    public var listeningDevice: UUID?
    /// The most recently active connected device.
    public var lastActiveDevice: UUID?
    /// The user's do-not-disturb switch, or quiet hours in effect.
    public var quiet: Bool
    /// The owner's spoken media mode (#551).
    public var media: Bool

    public init(listeningDevice: UUID? = nil, lastActiveDevice: UUID? = nil, quiet: Bool = false, media: Bool = false) {
        (self.listeningDevice, self.lastActiveDevice, self.quiet, self.media) =
            (listeningDevice, lastActiveDevice, quiet, media)
    }

    /// The device in a live ambient session, else the last active device.
    public var target: UUID? { listeningDevice ?? lastActiveDevice }
}

/// The opt-in settings for unsolicited updates. Off unless the user turns it on.
public struct SessionUpdatePolicy: Sendable, Equatable {
    public var enabled: Bool
    /// Updates one session may send per `window`, whether spoken or held.
    public var perSessionLimit: Int
    public var window: Duration
    /// Held updates kept at once; the oldest `info` is dropped first.
    public var capacity: Int
    /// A held update older than this is dropped unspoken.
    public var lifetime: Duration

    public init(
        enabled: Bool = false, perSessionLimit: Int = 6, window: Duration = .seconds(3_600), capacity: Int = 20,
        lifetime: Duration = .seconds(4 * 3_600)
    ) {
        (self.enabled, self.perSessionLimit, self.window) = (enabled, perSessionLimit, window)
        (self.capacity, self.lifetime) = (capacity, lifetime)
    }
}

/// Daily quiet hours as minutes after local midnight, `start` inclusive and `end` exclusive. A span that crosses
/// midnight (22:00 to 07:00) wraps; equal bounds mean no quiet hours.
public struct SessionUpdateQuietHours: Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init?(start: Int, end: Int) {
        let day = 0..<(24 * 60)
        guard day.contains(start), day.contains(end) else { return nil }
        (self.start, self.end) = (start, end)
    }

    public func contains(minuteOfDay minute: Int) -> Bool {
        if start == end { return false }
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return contains(minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}
