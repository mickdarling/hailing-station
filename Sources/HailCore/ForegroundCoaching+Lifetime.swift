import Foundation
import HailProtocol

// Same foreground lifetime: split only for the repository's file/type-size review limits.
@MainActor
extension ForegroundCoaching {
    func starting(_ id: UUID) -> Bool { epoch == id && status == .starting }

    func live(_ id: UUID) -> Bool {
        guard epoch == id, status == .active, let lease, let deadline else { return false }
        let now = clock.now()
        return epoch == id && status == .active && self.lease == lease && self.deadline == deadline
            && now < lease.expiresAt && now < deadline
    }

    func forward(_ buffer: AudioCaptureBuffer, lease source: CoachingQualification, epoch id: UUID) {
        guard live(id), lease == source, let transport else { return }
        guard transport.write(buffer), live(id), lease == source else { off(epoch: id); return }
    }

    func armHeartbeat(_ id: UUID) {
        cancelHeartbeat?()
        let revision = UUID()
        heartbeatRevision = revision
        let cancel = clock.schedule(.seconds(1)) { [weak self] in
            guard let self, self.heartbeatRevision == revision else { return }
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
        do {
            let advice = try audio.admit(data)
            guard live(id) else { off(epoch: id); return }
            rendering = true; sequence = 0; speechBytes = 0; speechFinal = false
            let revision = UUID()
            renderRevision = revision
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
        } catch { off(epoch: id) }
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
        renderTask = nil; rendering = false
        renderRevision = UUID()
        cancelRenderExpiry?(); cancelRenderExpiry = nil
        if status == .active, !succeeded || !speechFinal || !live(id) { off(epoch: id) }
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
