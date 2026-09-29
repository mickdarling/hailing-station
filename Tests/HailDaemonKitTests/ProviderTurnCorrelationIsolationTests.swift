import Foundation
import Testing
@testable import HailDaemonKit

extension ProviderTurnCorrelationTests {
    @Test func everyBindingFieldAndObservationGenerationIsChecked() throws {
        let fixture = try ProviderTestFixture()
        let original = fixture.binding
        let fields = [original.hostID, original.providerID, original.targetID, original.sessionID]
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        for index in 0...4 {
            var changed = fields
            if index < 4 { changed[index] += "-replacement" }
            let binding = try ProviderSessionBinding(
                hostID: changed[0], providerID: changed[1], targetID: changed[2], sessionID: changed[3],
                observationID: index == 4 ? UUID() : original.observationID
            )
            let stale = try ProviderSessionEvent(binding: binding, sequence: 0, kind: .finished)
            #expect(ledger.observe(stale) == .rejected(.wrongBinding))
        }
        #expect(ledger.observe(try fixture.event(0, .accepted)) == .associated(fixture.turn, state: .accepted))
    }

    @Test func reconnectAndUtteranceMismatchCannotReuseTurnIdentity() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        let oldConnection = ProviderTurnContext(
            id: fixture.turn.id, utteranceID: fixture.turn.utteranceID,
            connectionID: UUID(), binding: fixture.binding
        )
        let wrongUtterance = ProviderTurnContext(
            id: fixture.turn.id, utteranceID: UUID(), connectionID: fixture.connectionID, binding: fixture.binding
        )
        for (sequence, turn) in [oldConnection, wrongUtterance].enumerated() {
            let event = try ProviderSessionEvent(
                binding: fixture.binding, sequence: sequence, turn: turn, kind: .finished
            )
            #expect(ledger.observe(event) == .rejected(.wrongTurnContext))
            #expect(ledger.state(for: fixture.turn.id) == .sent)
        }
        #expect(throws: ProviderContractError.wrongContext) { try ledger.recordSent(oldConnection) }
        var newConnection = try ProviderTurnCorrelator(binding: fixture.binding, connectionID: UUID())
        #expect(throws: ProviderContractError.wrongContext) { try newConnection.recordSent(fixture.turn) }
        #expect(newConnection.observe(try fixture.event(0, .finished)) == .unassociated(.unknownTurn))
    }

    @Test func wrongBindingCannotBeRegisteredAsSent() throws {
        let fixture = try ProviderTestFixture()
        let other = try ProviderTestFixture()
        let mismatched = ProviderTurnContext(
            utteranceID: UUID(), connectionID: fixture.connectionID, binding: other.binding
        )
        var ledger = try fixture.correlator()
        #expect(throws: ProviderContractError.wrongContext) { try ledger.recordSent(mismatched) }
        #expect(ledger.state(for: mismatched.id) == nil)
    }

    @Test func boundedTombstonesRejectReuseWithoutEviction() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator(maxTurns: 2)
        try ledger.recordSent(fixture.turn)
        try ledger.timeOut(fixture.turn.id)
        let second = fixture.newTurn()
        try ledger.recordSent(second)
        let finished = try ProviderSessionEvent(binding: fixture.binding, sequence: 0, turn: second, kind: .finished)
        _ = ledger.observe(finished)
        #expect(throws: ProviderContractError.duplicateTurn) { try ledger.recordSent(fixture.turn) }
        #expect(throws: ProviderContractError.duplicateTurn) { try ledger.recordSent(second) }
        #expect(throws: ProviderContractError.capacityExceeded) { try ledger.recordSent(fixture.newTurn()) }
        #expect(ledger.observe(try fixture.event(1, .finished)) == .unassociated(.timedOut))
        #expect(ledger.state(for: second.id) == .finished)
    }

    @Test func eventCapacityAndSequenceGapFailWithoutInventingCompletion() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator(maxEvents: 1)
        try ledger.recordSent(fixture.turn)
        #expect(ledger.observe(try fixture.event(Int.max, .finished)) == .rejected(.sequenceGap))
        #expect(ledger.observe(try fixture.event(0, .running)) == .associated(fixture.turn, state: .running))
        #expect(ledger.observe(try fixture.event(1, .finished)) == .rejected(.capacityExceeded))
        #expect(ledger.state(for: fixture.turn.id) == .running)
    }

    @Test func capacitiesAndUnknownTimeoutsAreRejected() throws {
        let fixture = try ProviderTestFixture()
        for count in [0, -1, ProviderEventLimits.maxRetainedTurns + 1] {
            #expect(throws: ProviderContractError.invalidCapacity) { try fixture.correlator(maxTurns: count) }
        }
        for count in [0, -1, ProviderEventLimits.maxRetainedEvents + 1] {
            #expect(throws: ProviderContractError.invalidCapacity) { try fixture.correlator(maxEvents: count) }
        }
        var ledger = try fixture.correlator()
        #expect(throws: ProviderContractError.unknownTurn) { try ledger.timeOut(UUID()) }
    }
}
