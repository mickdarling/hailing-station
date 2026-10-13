public import Foundation

/// Local evidence supplied by a trusted output observer, never by the conversation or a requested route.
/// Bluetooth transport, device names and microphone selection alone cannot construct headphone evidence.
public enum CoachingOutputObservation: Sendable, Equatable {
    /// An actually observed output independently classified as headphones. The ID is an ephemeral topology token.
    case verifiedHeadphones(UUID)
    case unqualified
}

/// Exclusive renderer that MUST NOT activate/reconfigure the audio session or choose a fallback output.
/// Ordinary PCM16AudioPlayer deliberately does not conform: its prepare() may change the route before playing.
@MainActor
public protocol CoachingAudioPlaying: ReplyAudioPlaying {}

/// Host/terminal control correlation, not an authorization token for tools or actions (#225, #269).
public struct CoachingQualification: Sendable, Equatable {
    public let sessionID: UUID
    public let generation: UUID
    public let destinationID: UUID
    public let qualificationID: UUID
    public let expiresAt: ContinuousClock.Instant
    let outputID: UUID
}

/// Advice is tied to the exact private route lifetime that admitted its context.
public struct CoachingAdviceTicket: Sendable, Equatable {
    public let qualification: CoachingQualification
    public let requestID: UUID
}

public enum CoachingSuspension: Sendable, Equatable {
    case stopped, routeInvalidated, qualificationExpired, adviceExpired, captureEnded, captureFailed, playbackFailed
}

public enum CoachingSafetyError: Error, Sendable, Equatable {
    case consentRequired, unsafeOutput, invalidLifetime, staleQualification
    case transitionInProgress, invalidAudio, queueFull
}

/// Injectable monotonic clock/expiry scheduler. The real scheduler never records or plays audio.
@MainActor
public struct CoachingClock {
    public var now: @MainActor () -> ContinuousClock.Instant
    public var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    public init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void)
            -> @MainActor () -> Void = liveSchedule
    ) {
        self.now = now
        self.schedule = schedule
    }

    public static func liveSchedule(
        _ delay: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            fire()
        }
        return { task.cancel() }
    }
}
