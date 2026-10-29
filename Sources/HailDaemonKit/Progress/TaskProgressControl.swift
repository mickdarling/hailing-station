public import Foundation

/// A task enrollment, never a voice request or permission to recover/restart a provider (#1013).
public struct TaskProgressTask: Sendable, Equatable {
    public let id: UUID
    public let session: String
    public let binding: String

    public init(id: UUID = UUID(), session: String, binding: String) {
        (self.id, self.session, self.binding) = (id, session, binding)
    }
}

public enum TaskProgressOwnerControl: Sendable, Equatable {
    case interval(Duration)
    case moreOften
    case lessOften
    case pause
    case resume
    case stop
}

public enum TaskProgressControlResult: Sendable, Equatable {
    case applied
    case ownerControlled
    case invalidInterval
    case noTask
}

public enum TaskProgressPauseReason: String, Sendable, Equatable {
    case ownerPaused, ownerStopped, privacy, quiet, media, ownerSpeaking, playback
    case disconnected, notListening, ambiguousRecipient, outstanding
}

/// Authoritative host observations. Defaults refuse wakes until the owner and recipient are known.
public struct TaskProgressEnvironment: Sendable, Equatable {
    public var privateMode = false
    public var quiet = false
    public var media = false
    public var ownerSpeaking = false
    public var playback = false
    public var connected = false
    public var listening = false
    public var uniqueRecipient = false

    public init() {}

    public var pauseReason: TaskProgressPauseReason? {
        if privateMode { return .privacy }
        if quiet { return .quiet }
        if media { return .media }
        if !connected { return .disconnected }
        if !listening { return .notListening }
        if !uniqueRecipient { return .ambiguousRecipient }
        if ownerSpeaking { return .ownerSpeaking }
        return playback ? .playback : nil
    }
}

/// A single outstanding solicitation, tied to its original enrollment and generation.
public struct TaskProgressWake: Sendable, Equatable {
    public let task: TaskProgressTask
    public let token: UUID
}

public struct TaskProgressSnapshot: Sendable, Equatable {
    public let task: TaskProgressTask?
    public let interval: Duration
    public let setByOwner: Bool
    public let pauseReason: TaskProgressPauseReason?
    public let nextDue: ContinuousClock.Instant?
    public let outstanding: TaskProgressWake?
}

/// Sleep is cancellation-aware. No repeating timer or idle wake exists without a scheduled deadline.
public struct TaskProgressClock: Sendable {
    public let now: @Sendable () -> ContinuousClock.Instant
    public let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void
    ) {
        (self.now, self.sleepUntil) = (now, sleepUntil)
    }

    public static let continuous = TaskProgressClock(now: { .now }, sleepUntil: {
        try await Task.sleep(until: $0, clock: .continuous)
    })
}

extension TaskProgressOwnerControl {
    /// Deliberately exact owner commands. The caller must establish owner attribution before applying one;
    /// session text, quoted commands, and ordinary requests never become settings implicitly.
    public static func parse(_ text: String) -> Self? {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch command {
        case "updates more often", "progress updates more often": return .moreOften
        case "updates less often", "progress updates less often": return .lessOften
        case "pause updates", "pause progress updates": return .pause
        case "resume updates", "resume progress updates": return .resume
        case "stop updates", "stop progress updates": return .stop
        default: return parseInterval(command)
        }
    }

    private static func parseInterval(_ command: String) -> Self? {
        let words = command.split(separator: " ")
        let prefix = ["progress", "updates", "every"]
        guard words.count == 5, words.prefix(3).map(String.init) == prefix,
              let count = Int64(words[3]), count > 0 else { return nil }
        let multiplier: Int64
        switch words[4] {
        case "second", "seconds": multiplier = 1
        case "minute", "minutes": multiplier = 60
        case "hour", "hours": multiplier = 3_600
        default: return nil
        }
        let (seconds, overflow) = count.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { return nil }
        let interval = Duration.seconds(seconds)
        guard interval >= TaskProgressState.minimumInterval,
              interval <= TaskProgressState.maximumInterval else { return nil }
        return .interval(interval)
    }
}
