import Foundation
import HailProtocol

@MainActor
extension ForegroundCoaching {
    func receive(_ data: Data, epoch id: UUID) {
        guard live(id), !rendering, let audio else { return }
        // Admission observes callback-capable clocks/routes. Reserve ownership BEFORE entering it.
        rendering = true; renderInterrupted = false; speechFailure = nil
        let revision = UUID()
        renderRevision = revision
        do {
            audio.interruptSpeech() // A new owned cue supersedes queued speech, never overlaps it.
            let advice = try audio.prepareSpeech(audio.admit(data))
            guard live(id), renderRevision == revision, !renderInterrupted else {
                renderFinished(id, revision: revision, succeeded: false); return
            }
            sequence = 0; speechBytes = 0; speechFinal = false; speechPayloads = []
            let now = clock.now()
            guard live(id), now < advice.ticket.expiresAt else {
                rendering = false; off(epoch: id); finishRetirement(); return
            }
            let cancel = clock.schedule(now.duration(to: advice.ticket.expiresAt)) { [weak self] in
                guard let self, self.renderRevision == revision else { return }
                self.off(epoch: id)
            }
            guard live(id), rendering else {
                cancel(); rendering = false; finishRetirement(); return
            }
            cancelRenderExpiry = cancel
            startRender(advice, epoch: id, revision: revision)
        } catch {
            if !renderInterrupted { off(epoch: id) }; renderFinished(id, revision: revision, succeeded: false)
        }
    }

    func startRender(_ advice: AdmittedCoachingAdvice, epoch id: UUID, revision: UUID) {
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
                try self?.play(advice, epoch: id, revision: revision)
                succeeded = true
            } catch let failure as CoachingSpeechFailure {
                self?.speechFailed(failure, epoch: id, revision: revision)
            } catch { /* Content-free failure: never log advice or provider output. */ }
            self?.renderFinished(id, revision: revision, succeeded: succeeded)
        }
    }

    func speechFailed(_ failure: CoachingSpeechFailure, epoch id: UUID, revision: UUID) {
        guard epoch == id, status == .active, renderRevision == revision, !renderInterrupted else { return }
        speechFailure = failure
        audio?.interruptSpeech()
    }

    func renderMayStart(_ advice: AdmittedCoachingAdvice, epoch id: UUID, revision: UUID,
                        remaining: Duration = .zero) -> Bool {
        guard live(id), rendering, !renderInterrupted, renderRevision == revision,
              let lease, let deadline else { return false }
        let now = clock.now()
        // No callback follows the final clock read: both current authority and ORIGINAL work deadline.
        return epoch == id && status == .active && rendering && !renderInterrupted && renderRevision == revision
            && self.lease == lease && self.deadline == deadline
            && lease.sessionID == advice.ticket.qualification.sessionID
            && lease.generation == advice.ticket.qualification.generation
            && lease.destinationID == advice.ticket.qualification.destinationID
            && lease.outputID == advice.ticket.qualification.outputID
            && now < lease.expiresAt && now < deadline && now.advanced(by: remaining) < advice.ticket.expiresAt
    }

    func emit(_ payload: AudioPayload, advice: AdmittedCoachingAdvice,
              epoch id: UUID, revision: UUID) throws {
        guard renderMayStart(advice, epoch: id, revision: revision), !speechFinal,
              payload.sequence == sequence, sequence < 32,
              payload.codec == .pcm16, payload.sampleRate == 24_000, payload.channels == 1,
              !payload.bytes.isEmpty, payload.bytes.count.isMultiple(of: 2), payload.bytes.count <= 48_000,
              payload.bytes.count <= CoachingSpeechBudget.pcmBytes - speechBytes else {
            throw ForegroundCoachingError.invalidSpeech
        }
        sequence += 1; speechBytes += payload.bytes.count; speechFinal = payload.isFinal
        speechPayloads.append(payload) // No player effects until the complete phrase and owned cleanup succeed.
    }

    func play(_ advice: AdmittedCoachingAdvice, epoch id: UUID, revision: UUID) throws {
        guard renderMayStart(advice, epoch: id, revision: revision), speechFinal, let audio else {
            throw ForegroundCoachingError.invalidSpeech
        }
        let duration = Duration.milliseconds((speechBytes * 1_000 + 47_999) / 48_000)
        guard renderMayStart(advice, epoch: id, revision: revision, remaining: duration) else {
            throw CoachingSpeechFailure.durationExceeded
        }
        try audio.playCompletePhrase(speechPayloads, for: advice)
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
        let interrupted = renderInterrupted
        rendering = false; renderInterrupted = false; speechPayloads = []
        if status == .active, (!completed && !interrupted && speechFailure == nil) || !live(id) { off(epoch: id) }
        finishRetirement()
    }
}
