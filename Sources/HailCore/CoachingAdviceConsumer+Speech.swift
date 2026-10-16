import Foundation

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
