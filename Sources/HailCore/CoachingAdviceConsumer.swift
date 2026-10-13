public import Foundation
public import HailProtocol

/// Immutable admission result. Every asynchronous renderer must return through this consumer's scheduling gate.
public struct AdmittedCoachingAdvice: Sendable {
    public let text: String
    public let ticket: CoachingAdviceTicket
    let consumerID: UUID
}

/// Local, default-off wire boundary. Host controls and speech/model text cannot issue qualifications here.
/// The owner calls register after actual begin/renew, and invalidate/stop on every route/session/connection loss.
@MainActor
public final class CoachingAdviceConsumer {
    public static let qualificationLimit = 16
    public static let requestLimit = 128
    private let session: PrivateCoachingSession
    private let listenerID: String
    private let consumerID = UUID()
    private var generation: UUID?
    private var qualifications: [UUID: CoachingQualification] = [:]
    private var requests: Set<UUID> = []
    private var admitted: [UUID: CoachingAdviceTicket] = [:]

    public init(session: PrivateCoachingSession, listenerID: String) throws {
        guard CoachingWireAdvice.identifier(listenerID) else { throw CoachingWireError.invalidMessage }
        self.session = session
        self.listenerID = listenerID
    }

    /// Only an exact still-current host-issued lease can enter. Re-registration never extends a deadline.
    public func register(_ lease: CoachingQualification) throws {
        guard session.current() == lease else { throw CoachingWireError.unknownQualification }
        if generation != lease.generation { clear(); generation = lease.generation }
        prune()
        if let original = qualifications[lease.qualificationID] {
            guard original == lease else { throw CoachingWireError.unknownQualification }
            return
        }
        guard qualifications.count < Self.qualificationLimit else { try exhaust() }
        qualifications[lease.qualificationID] = lease
    }

    public func admit(_ data: Data) throws -> AdmittedCoachingAdvice {
        let wire = try CoachingWireAdvice.decode(data)
        guard let live = session.current(), live.generation == generation else {
            clear(); throw CoachingWireError.staleAdvice
        }
        prune()
        guard let qualificationID = UUID(uuidString: wire.qualificationID),
              let lease = qualifications[qualificationID] else { throw CoachingWireError.unknownQualification }
        guard wire.sessionID == lease.sessionID.uuidString.lowercased(),
              wire.generationID == lease.generation.uuidString.lowercased(),
              wire.destinationID == lease.destinationID.uuidString.lowercased(), wire.listenerID == listenerID,
              let requestID = UUID(uuidString: wire.requestID) else { throw CoachingWireError.wrongScope }
        try validateRequest(requestID)
        let deadline = min(lease.expiresAt, session.clock.now().advanced(by: .milliseconds(wire.validForMs)))
        let ticket = CoachingAdviceTicket(qualification: CoachingQualification(
            sessionID: lease.sessionID, generation: lease.generation, destinationID: lease.destinationID,
            qualificationID: lease.qualificationID, expiresAt: deadline, outputID: lease.outputID
        ), requestID: requestID)
        try session.validate(ticket)
        // Output observation may synchronously reenter admission. Commit only against the resulting ledger.
        guard generation == lease.generation, qualifications[qualificationID] == lease else {
            throw CoachingWireError.staleAdvice
        }
        try validateRequest(requestID)
        requests.insert(requestID) // Never pruned inside a generation: expiry cannot make a request replayable.
        admitted[requestID] = ticket
        return AdmittedCoachingAdvice(text: wire.text, ticket: ticket, consumerID: consumerID)
    }

    /// Delayed renderer chunks are admitted at consumption, not just when text was received.
    public func schedule(_ payload: AudioPayload, for advice: AdmittedCoachingAdvice) throws {
        try validate(advice)
        try session.schedule(payload, ticket: advice.ticket)
    }

    public func resume(_ advice: AdmittedCoachingAdvice) throws {
        try validate(advice)
        try session.resume(ticket: advice.ticket)
    }

    public func setMuted(_ muted: Bool, for advice: AdmittedCoachingAdvice) throws {
        try validate(advice)
        try session.setMuted(muted, ticket: advice.ticket)
    }

    public func invalidate() { clear(); session.invalidateRoute() }
    public func stop() { clear(); session.stop() }

    private func validate(_ advice: AdmittedCoachingAdvice) throws {
        guard let live = session.current(), live.generation == generation else {
            clear(); throw CoachingWireError.staleAdvice
        }
        prune()
        guard advice.consumerID == consumerID, admitted[advice.ticket.requestID] == advice.ticket,
              qualifications[advice.ticket.qualification.qualificationID] != nil else {
            throw CoachingWireError.staleAdvice
        }
        try session.validate(advice.ticket)
    }

    private func prune() {
        let now = session.clock.now()
        qualifications = qualifications.filter { now < $0.value.expiresAt }
        admitted = admitted.filter { now < $0.value.qualification.expiresAt }
    }

    private func validateRequest(_ requestID: UUID) throws {
        guard !requests.contains(requestID) else { throw CoachingWireError.replay }
        guard requests.count < Self.requestLimit else { try exhaust() }
    }

    private func clear() {
        generation = nil
        qualifications.removeAll()
        requests.removeAll()
        admitted.removeAll()
    }

    private func exhaust() throws -> Never {
        stop()
        throw CoachingWireError.ledgerFull
    }
}
