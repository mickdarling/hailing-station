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

    func contextChanged(epoch id: UUID) {
        guard epoch == id, status == .active else { return }
        if rendering {
            renderInterrupted = true
            let cancel = cancelRenderExpiry; cancelRenderExpiry = nil
            renderTask?.cancel(); speech.cancel(); cancel?()
        }
        audio?.interruptSpeech()
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
