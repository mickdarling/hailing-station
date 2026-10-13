import Foundation

extension PrivateCoachingSession {
    func validate(_ ticket: CoachingAdviceTicket) throws {
        guard !transitioning, let live = current(), sameScope(ticket.qualification, live),
              clock.now() < ticket.qualification.expiresAt else { throw CoachingSafetyError.staleQualification }
    }

    func sameScope(_ lhs: CoachingQualification, _ rhs: CoachingQualification) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.generation == rhs.generation
            && lhs.destinationID == rhs.destinationID && lhs.outputID == rhs.outputID
    }

    func current() -> CoachingQualification? {
        guard let live = qualification else { return nil }
        guard clock.now() < live.expiresAt else { suspend(.qualificationExpired); return nil }
        guard pendingPlayback.values.allSatisfy({ clock.now() < $0 }) else {
            suspend(.adviceExpired); return nil
        }
        guard observeOutput() == .verifiedHeadphones(live.outputID) else { suspend(.routeInvalidated); return nil }
        // Trusted resource callbacks may invalidate synchronously; never return a retired snapshot.
        guard qualification == live else { return nil }
        return live
    }

    func armExpiry(_ lease: CoachingQualification) {
        cancelExpiry?()
        let deadline = min(lease.expiresAt, pendingPlayback.values.min() ?? lease.expiresAt)
        let revision = UUID()
        expiryRevision = revision
        cancelExpiry = clock.schedule(clock.now().duration(to: deadline)) { [weak self] in
            guard let self, self.expiryRevision == revision, let live = self.qualification else { return }
            // Early scheduler callbacks cannot accidentally expire a still-live lease.
            if self.current() != nil { self.armExpiry(live) }
        }
    }

    func suspend(_ reason: CoachingSuspension) {
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
        if captureStarted { captureStarted = false; capture.stop() }
        hooks.suspended(old, reason)
    }
}
