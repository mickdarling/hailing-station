import Foundation

extension PrivateCoachingSession {
    func requireStartup(_ revision: UUID) throws {
        guard startupRevision == revision else { throw CoachingSafetyError.staleQualification }
    }

    func startupLease(
        sessionID: UUID, destinationID: UUID, lifetime: Duration, revision: UUID
    ) throws -> CoachingQualification {
        let observed = observeOutput()
        try requireStartup(revision)
        guard case .verifiedHeadphones(let outputID) = observed else { throw CoachingSafetyError.unsafeOutput }
        let now = clock.now()
        try requireStartup(revision)
        return CoachingQualification(sessionID: sessionID, generation: UUID(), destinationID: destinationID,
            qualificationID: UUID(), expiresAt: now.advanced(by: lifetime), outputID: outputID)
    }

    func startOwnedCapture() throws -> AsyncStream<AudioCaptureBuffer> {
        captureStarted = true // A partially failed start still owns cleanup until it returns.
        captureStarting = true
        defer {
            captureStarting = false
            if qualification == nil, captureStarted { captureStarted = false; capture.stop() }
        }
        return try capture.start()
    }

    func forwardSource(_ source: AsyncStream<AudioCaptureBuffer>, generation: UUID) {
        forward = Task { @MainActor [weak self] in
            for await buffer in source {
                guard !Task.isCancelled, let self else { break }
                guard let live = self.current() else {
                    // A same-generation renewal can supersede this observation synchronously.
                    // Drop only this unqualified buffer, not the still-owned source subscription.
                    guard self.qualification?.generation == generation else { break }
                    continue
                }
                guard live.generation == generation else { break }
                self.hooks.buffer(buffer, live)
            }
            guard let self, self.qualification?.generation == generation else { return }
            self.suspend(.captureEnded)
        }
    }

    func validate(_ ticket: CoachingAdviceTicket) throws {
        guard !transitioning, let live = current(), sameScope(ticket.qualification, live) else {
            throw CoachingSafetyError.staleQualification
        }
        let now = clock.now()
        guard !transitioning, qualification == live, hasLiveDeadlines(live, at: now),
              now < ticket.qualification.expiresAt else {
            throw CoachingSafetyError.staleQualification
        }
    }

    func sameScope(_ lhs: CoachingQualification, _ rhs: CoachingQualification) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.generation == rhs.generation
            && lhs.destinationID == rhs.destinationID && lhs.outputID == rhs.outputID
    }

    func current() -> CoachingQualification? {
        guard let live = qualification, hasLiveDeadlines(live) else { return nil }
        let observed = observeOutput()
        // Observation can synchronously replace/renew ownership. An old snapshot cannot retire its successor.
        guard qualification == live else { return nil }
        guard observed == .verifiedHeadphones(live.outputID) else { suspend(.routeInvalidated); return nil }
        // Trusted resource callbacks may invalidate synchronously; never return a retired snapshot.
        guard qualification == live, hasLiveDeadlines(live) else { return nil }
        return live
    }

    private func hasLiveDeadlines(_ live: CoachingQualification) -> Bool {
        hasLiveDeadlines(live, at: clock.now())
    }

    func hasLiveDeadlines(_ live: CoachingQualification, at now: ContinuousClock.Instant) -> Bool {
        guard qualification == live else { return false }
        guard now < live.expiresAt else { suspend(.qualificationExpired); return false }
        guard pendingPlayback.values.allSatisfy({ now < $0 }) else { suspend(.adviceExpired); return false }
        return true
    }

    func armExpiry(_ lease: CoachingQualification) {
        let previous = cancelExpiry
        cancelExpiry = nil
        previous?()
        guard qualification == lease else { return }
        let deadline = min(lease.expiresAt, pendingPlayback.values.min() ?? lease.expiresAt)
        let revision = UUID()
        expiryRevision = revision
        let cancel = clock.schedule(clock.now().duration(to: deadline)) { [weak self] in
            guard let self, self.expiryRevision == revision, let live = self.qualification else { return }
            // Early scheduler callbacks cannot accidentally expire a still-live lease.
            if self.current() != nil { self.armExpiry(live) }
        }
        if qualification == lease, expiryRevision == revision { cancelExpiry = cancel } else { cancel() }
    }

    func suspend(
        _ reason: CoachingSuspension, ifGeneration generation: UUID? = nil, invalidatesStartup: Bool = true
    ) {
        guard generation == nil || qualification?.generation == generation else { return }
        if invalidatesStartup { startupRevision = UUID() }
        guard let old = qualification else { return }
        let wasTransitioning = transitioning
        transitioning = true
        defer { transitioning = wasTransitioning }
        qualification = nil // Fence callbacks BEFORE stopping any resource.
        expiryRevision = UUID()
        cancelExpiry?()
        cancelExpiry = nil
        forward?.cancel()
        forward = nil
        pendingPlayback.removeAll()
        player.cancel()
        if captureStarted {
            if !captureStarting { captureStarted = false }
            capture.stop()
        }
        hooks.suspended(old, reason)
    }
}
