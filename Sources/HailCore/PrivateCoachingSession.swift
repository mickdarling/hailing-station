public import Foundation
public import HailProtocol

/// Default-off, local private-coaching lifetime. No app, transport or daemon activates it by merging this library.
/// Its exclusive capture/player must not also be driven by ordinary playback. All admissions and invalidation
/// run on the main actor. The platform adapter must invalidate BEFORE rebuilding/changing the audio route.
@MainActor
public final class PrivateCoachingSession {
    public static let maximumLifetime: Duration = .seconds(2)
    public internal(set) var qualification: CoachingQualification?

    let capture: any AudioCapturing
    let player: any CoachingAudioPlaying
    let observeOutput: () -> CoachingOutputObservation
    let clock: CoachingClock
    var forward: Task<Void, Never>?
    var cancelExpiry: (@MainActor () -> Void)?
    var expiryRevision = UUID()
    var captureStarted = false
    var captureStarting = false
    var startupRevision = UUID()
    var transitioning = false
    var pendingPlayback: [UUID: ContinuousClock.Instant] = [:]

    /// Buffer recipients must carry this qualification through any asynchronous work and discard on suspension.
    public struct Hooks {
        public var buffer: (AudioCaptureBuffer, CoachingQualification) -> Void
        /// Cancel downstream provider/render work and clear coaching context. No automatic re-admission.
        public var suspended: (CoachingQualification, CoachingSuspension) -> Void

        public init(
            buffer: @escaping (AudioCaptureBuffer, CoachingQualification) -> Void,
            suspended: @escaping (CoachingQualification, CoachingSuspension) -> Void
        ) {
            self.buffer = buffer
            self.suspended = suspended
        }
    }

    let hooks: Hooks

    public init(
        capture: any AudioCapturing, player: any CoachingAudioPlaying,
        observeOutput: @escaping () -> CoachingOutputObservation, hooks: Hooks, clock: CoachingClock = .init()
    ) {
        self.capture = capture
        self.player = player
        self.observeOutput = observeOutput
        self.hooks = hooks
        self.clock = clock
    }

    isolated deinit {
        let old = qualification
        qualification = nil
        transitioning = true
        cancelExpiry?()
        forward?.cancel()
        player.cancel()
        if captureStarted { capture.stop() }
        if let old { hooks.suspended(old, .stopped) }
    }

    /// Explicit opt-in AND participant-awareness/consent are required. The caller supplies opaque local IDs.
    /// This is raw/plain capture, not AEC: private output is its separate safety precondition.
    @discardableResult
    public func begin(
        sessionID: UUID, destinationID: UUID, consentConfirmed: Bool,
        lifetime: Duration = maximumLifetime
    ) throws -> CoachingQualification {
        guard !transitioning else { throw CoachingSafetyError.transitionInProgress }
        transitioning = true
        defer { transitioning = false }
        let revision = UUID()
        startupRevision = revision
        suspend(.stopped, invalidatesStartup: false)
        try requireStartup(revision)
        guard consentConfirmed else { throw CoachingSafetyError.consentRequired }
        guard lifetime > .zero, lifetime <= Self.maximumLifetime else { throw CoachingSafetyError.invalidLifetime }
        let lease = try startupLease(sessionID: sessionID, destinationID: destinationID,
                                     lifetime: lifetime, revision: revision)
        qualification = lease
        do {
            let source = try startOwnedCapture()
            try requireStartup(revision)
            // Starting an engine can itself change the actual output route.
            guard current()?.generation == lease.generation else { throw CoachingSafetyError.unsafeOutput }
            armExpiry(lease)
            guard current() == lease else { throw CoachingSafetyError.staleQualification }
            forwardSource(source, generation: lease.generation)
            return lease
        } catch {
            suspend(.captureFailed, ifGeneration: lease.generation)
            throw error
        }
    }

    /// Renew only the still-live generation, on the SAME verified actual output. Expired generations never revive.
    @discardableResult
    public func renew(_ lease: CoachingQualification, lifetime: Duration = maximumLifetime) throws
        -> CoachingQualification {
        guard lifetime > .zero, lifetime <= Self.maximumLifetime else { throw CoachingSafetyError.invalidLifetime }
        guard !transitioning, let live = current(), lease == live else {
            throw CoachingSafetyError.staleQualification
        }
        let now = clock.now()
        guard !transitioning, qualification == live, hasLiveDeadlines(live, at: now) else {
            throw CoachingSafetyError.staleQualification
        }
        let renewed = CoachingQualification(
            sessionID: live.sessionID, generation: live.generation, destinationID: live.destinationID,
            qualificationID: UUID(), expiresAt: now.advanced(by: lifetime), outputID: live.outputID
        )
        qualification = renewed
        armExpiry(renewed)
        guard current() == renewed else { throw CoachingSafetyError.staleQualification }
        return renewed
    }

    public func ticket(requestID: UUID) throws -> CoachingAdviceTicket {
        guard !transitioning, let live = current() else { throw CoachingSafetyError.staleQualification }
        return CoachingAdviceTicket(qualification: live, requestID: requestID)
    }

    /// Every chunk is checked immediately before it reaches the player; queued audio is cancelled on invalidation.
    public func schedule(_ payload: AudioPayload, ticket: CoachingAdviceTicket) throws {
        try validate(ticket)
        guard payload.codec == .pcm16, payload.channels == 1, payload.sampleRate == 24_000,
              payload.sequence >= 0, !payload.bytes.isEmpty, payload.bytes.count <= 48_000,
              payload.bytes.count.isMultiple(of: 2) else {
            throw CoachingSafetyError.invalidAudio
        }
        guard pendingPlayback.count < 32 else { throw CoachingSafetyError.queueFull }
        let chunkID = UUID()
        pendingPlayback[chunkID] = ticket.qualification.expiresAt
        if let live = qualification { armExpiry(live) }
        try validate(ticket) // Scheduler/cancellation hooks may synchronously invalidate the lifetime.
        do { try player.schedule(payload, onPlayed: { [weak self] in
            guard let self, self.pendingPlayback[chunkID] != nil, let live = self.current() else { return }
            self.pendingPlayback[chunkID] = nil // Check authoritative time BEFORE erasing the original deadline.
            self.armExpiry(live)
        }) } catch {
            suspend(.playbackFailed, ifGeneration: ticket.qualification.generation)
            throw error
        }
    }

    public func resume(ticket: CoachingAdviceTicket) throws {
        try validate(ticket)
        do { try player.resume() } catch {
            suspend(.playbackFailed, ifGeneration: ticket.qualification.generation)
            throw error
        }
    }

    public func setMuted(_ muted: Bool, ticket: CoachingAdviceTicket) throws {
        try validate(ticket)
        player.setMuted(muted)
    }

    /// Any route notification invalidates, even if a later snapshot looks private again. Call before async rebuild.
    public func invalidateRoute() { suspend(.routeInvalidated) }
    public func stop() { suspend(.stopped) }
}
