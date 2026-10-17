import Foundation
import HailProtocol

// Same foreground lifetime: split only for the repository's file/type-size review limits.
@MainActor
extension ForegroundCoaching {
    func starting(_ id: UUID) -> Bool { epoch == id && status == .starting }

    func live(_ id: UUID) -> Bool {
        guard epoch == id, status == .active, let lease, let deadline else { return false }
        let now = clock.now()
        guard epoch == id, status == .active, self.deadline == deadline else { return false }
        guard now < deadline else { off(epoch: id); return false }
        guard self.lease == lease else { return false }
        guard now < lease.expiresAt else { off(epoch: id); return false }
        return true
    }

    func forward(_ buffer: AudioCaptureBuffer, lease source: CoachingQualification, epoch id: UUID) {
        guard live(id), lease == source, let transport else { return }
        guard transport.write(buffer), live(id), lease == source else { off(epoch: id); return }
    }

    func armHeartbeat(_ id: UUID) {
        let revision = UUID()
        heartbeatRevision = revision
        let oldCancel = cancelHeartbeat
        cancelHeartbeat = nil
        oldCancel?()
        guard live(id), heartbeatRevision == revision else { return }
        let cancel = clock.schedule(.seconds(1)) { [weak self] in
            guard let self, self.heartbeatRevision == revision else { return }
            // Consume timer authority before renewal/cancellation can synchronously redeliver it.
            self.heartbeatRevision = UUID()
            let firedCancel = self.cancelHeartbeat
            self.cancelHeartbeat = nil
            firedCancel?()
            self.heartbeat(id)
        }
        guard epoch == id, status == .active, heartbeatRevision == revision else { cancel(); return }
        cancelHeartbeat = cancel
    }

    func heartbeat(_ id: UUID) {
        guard live(id), let old = lease, let audio, let transport else { off(epoch: id); return }
        do {
            let fresh = try audio.renew(old)
            guard live(id), lease == old else { off(epoch: id); return }
            lease = fresh
            guard transport.send(.qualify(fresh)), live(id), lease == fresh else {
                off(epoch: id); return
            }
            armHeartbeat(id)
        } catch { off(epoch: id) }
    }

    func receive(_ data: Data, epoch id: UUID) {
        guard live(id), !rendering, let audio else { return }
        // Admission observes callback-capable clocks/routes. Reserve ownership BEFORE entering it.
        rendering = true
        let revision = UUID()
        renderRevision = revision
        do {
            let advice = try audio.admit(data)
            guard live(id), renderRevision == revision else {
                rendering = false; off(epoch: id); finishRetirement(); return
            }
            sequence = 0; speechBytes = 0; speechFinal = false
            let now = clock.now()
            guard live(id), now < advice.ticket.qualification.expiresAt else {
                rendering = false; off(epoch: id); finishRetirement(); return
            }
            let cancel = clock.schedule(now.duration(to: advice.ticket.qualification.expiresAt)) { [weak self] in
                guard let self, self.renderRevision == revision else { return }
                self.off(epoch: id)
            }
            guard live(id), rendering else {
                cancel(); rendering = false; finishRetirement(); return
            }
            cancelRenderExpiry = cancel
            renderTask = Task { [weak self, speech] in
                guard !Task.isCancelled, self?.renderMayStart(advice, epoch: id, revision: revision) == true else {
                    self?.renderFinished(id, revision: revision, succeeded: false)
                    return
                }
                var succeeded = false
                do {
                    try await speech.render(advice.text) { [weak self] payload in
                        guard let self else { throw ForegroundCoachingError.startupLost }
                        try self.emit(payload, advice: advice, epoch: id, revision: revision)
                    }
                    succeeded = true
                } catch { /* Content-free failure: never log advice or provider output. */ }
                self?.renderFinished(id, revision: revision, succeeded: succeeded)
            }
        } catch { rendering = false; off(epoch: id); finishRetirement() }
    }

    func renderMayStart(_ advice: AdmittedCoachingAdvice, epoch id: UUID, revision: UUID) -> Bool {
        guard live(id), rendering, renderRevision == revision, let lease, let deadline else { return false }
        let now = clock.now()
        // No callback follows the final clock read: both current authority and ORIGINAL work deadline.
        return epoch == id && status == .active && rendering && renderRevision == revision
            && self.lease == lease && self.deadline == deadline
            && lease.sessionID == advice.ticket.qualification.sessionID
            && lease.generation == advice.ticket.qualification.generation
            && lease.destinationID == advice.ticket.qualification.destinationID
            && lease.outputID == advice.ticket.qualification.outputID
            && now < lease.expiresAt && now < deadline && now < advice.ticket.qualification.expiresAt
    }

    func emit(_ payload: AudioPayload, advice: AdmittedCoachingAdvice,
              epoch id: UUID, revision: UUID) throws {
        guard live(id), rendering, renderRevision == revision, !speechFinal, payload.sequence == sequence,
              sequence < 32, payload.bytes.count <= 96_000 - speechBytes, let audio else {
            throw ForegroundCoachingError.invalidSpeech
        }
        // Commit limits before callback-capable scheduling/resume. The audio owner checks format,
        // original ticket deadline and final actual output immediately before private effects.
        sequence += 1; speechBytes += payload.bytes.count; speechFinal = payload.isFinal
        try audio.schedule(payload, for: advice)
        guard live(id), rendering else { throw ForegroundCoachingError.startupLost }
        if sequence == 1 { try audio.resume(advice) }
    }

    func renderFinished(_ id: UUID, revision: UUID, succeeded: Bool) {
        guard epoch == id else { return }
        // Retirement invalidates effects but the same job still owns its join slot.
        guard status == .retiring || renderRevision == revision else { return }
        let completed = succeeded && speechFinal && live(id)
        renderTask = nil
        renderRevision = UUID()
        let oldCancel = cancelRenderExpiry
        cancelRenderExpiry = nil
        oldCancel?() // Hold the admission/join slot throughout callback-capable cancellation.
        rendering = false
        if status == .active, !completed || !live(id) { off(epoch: id) }
        finishRetirement()
    }

    func off(epoch id: UUID) {
        guard epoch == id, status != .off, status != .retiring else { return }
        status = .retiring
        let oldLease = lease, child = transport, owner = audio
        lease = nil; deadline = nil; transport = nil; audio = nil
        heartbeatRevision = UUID(); renderRevision = UUID()
        cancelHeartbeat?(); cancelHeartbeat = nil
        cancelRenderExpiry?(); cancelRenderExpiry = nil
        renderTask?.cancel()
        // All authority is gone before cancellation/stop callbacks can reenter.
        speech.cancel(); owner?.stop()
        if let child {
            if let oldLease { _ = child.send(.disable(sessionID: oldLease.sessionID)) }
            retire(child)
        }
        finishRetirement()
    }

    func retire(_ child: any ForegroundCoachingTransport) {
        retiringJobs += 1
        child.close()
        let id = epoch
        Task { [weak self] in
            await child.stop()
            guard let self, self.epoch == id else { return }
            self.retiringJobs -= 1
            self.finishRetirement()
        }
    }

    func finishRetirement() {
        if status == .retiring, !startupInFlight, retiringJobs == 0, !rendering { status = .off }
    }
}
