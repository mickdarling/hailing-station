import Foundation
public import HailProtocol

@MainActor
extension CoachingAdviceConsumer {
    /// Promote only an owned, still-fresh admission once. Wire/model data never supplies this deadline.
    public func prepareSpeech(_ advice: AdmittedCoachingAdvice) throws -> AdmittedCoachingAdvice {
        let revision = speechRevision
        try validate(advice)
        let live = session.qualification
        let now = session.clock.now()
        guard !interruptingSpeech, revision == speechRevision, let live, session.qualification == live,
              live.generation == generation, session.sameScope(advice.ticket.qualification, live),
              now < live.expiresAt, admitted[advice.ticket.requestID] == advice.ticket else {
            throw CoachingWireError.staleAdvice
        }
        let ticket = try advice.ticket.permittingSpeech(at: now)
        admitted[ticket.requestID] = ticket
        return AdmittedCoachingAdvice(text: advice.text, ticket: ticket, consumerID: consumerID)
    }

    public func playCompletePhrase(_ payloads: [AudioPayload], for advice: AdmittedCoachingAdvice) throws {
        try validate(advice)
        try session.playCompletePhrase(payloads, ticket: advice.ticket)
    }

    /// Revoke the ledger before callback-capable player cancellation; keep replay fencing and capture.
    public func interruptSpeech() {
        guard !interruptingSpeech else { return }
        interruptingSpeech = true
        defer { interruptingSpeech = false }
        speechRevision = UUID()
        admitted.removeAll()
        session.cancelSpeech()
    }
}

@MainActor
extension PrivateCoachingSession {
    static func phraseDuration(_ payloads: [AudioPayload]) throws -> Duration {
        guard !payloads.isEmpty, payloads.count <= 32 else { throw CoachingSafetyError.invalidAudio }
        var bytes = 0
        for (index, payload) in payloads.enumerated() {
            guard payload.codec == .pcm16, payload.channels == 1, payload.sampleRate == 24_000,
                  payload.sequence == index, payload.isFinal == (index == payloads.count - 1),
                  !payload.bytes.isEmpty, payload.bytes.count <= 48_000,
                  payload.bytes.count.isMultiple(of: 2) else { throw CoachingSafetyError.invalidAudio }
            guard payload.bytes.count <= CoachingSpeechBudget.pcmBytes - bytes else {
                throw CoachingSpeechFailure.durationExceeded
            }
            bytes += payload.bytes.count
        }
        return .milliseconds((bytes * 1_000 + 47_999) / 48_000)
    }

    func playCompletePhrase(_ payloads: [AudioPayload], ticket: CoachingAdviceTicket) throws {
        try validate(ticket)
        _ = try Self.phraseDuration(payloads)
        guard pendingPlayback.count < 32 else { throw CoachingSafetyError.queueFull }
        let phraseID = UUID()
        pendingPlayback[phraseID] = ticket.expiresAt
        if let live = qualification { armExpiry(live) }
        try performPlayerEffect(ticket) {
            try player.replaceQueue(with: payloads, onPlayed: { [weak self] in
                guard let self, self.pendingPlayback[phraseID] != nil, let live = self.current() else { return }
                self.pendingPlayback[phraseID] = nil
                self.armExpiry(live)
            })
        }
    }
}
