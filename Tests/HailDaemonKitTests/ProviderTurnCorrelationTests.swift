import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderTurnCorrelationTests {
    @Test func sentTextAndExplicitLifecycleAreDistinct() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        #expect(ledger.state(for: fixture.turn.id) == .sent)
        let finalText = try fixture.event(0, .text("Synthetic reply", isFinal: true, visibility: .userVisible))
        #expect(ledger.observe(finalText) == .associated(fixture.turn, state: .sent))
        #expect(ledger.observe(try fixture.event(1, .accepted)) == .associated(fixture.turn, state: .accepted))
        #expect(ledger.observe(try fixture.event(2, .running)) == .associated(fixture.turn, state: .running))
        #expect(ledger.observe(try fixture.event(3, .finished)) == .associated(fixture.turn, state: .finished))
        #expect(ledger.observe(try fixture.event(4, .running)) == .rejected(.turnEnded))
        #expect(ledger.state(for: fixture.turn.id) == .finished)
    }

    @Test func repeatedTimedOutRepliesNeverCompleteNewerTurns() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        let turns = [fixture.turn, fixture.newTurn(), fixture.newTurn()]
        for turn in turns {
            try ledger.recordSent(turn)
            try ledger.timeOut(turn.id)
        }
        let current = fixture.newTurn()
        try ledger.recordSent(current)
        for (sequence, turn) in turns.enumerated() {
            let late = try ProviderSessionEvent(
                binding: fixture.binding, sequence: sequence, turn: turn, kind: .finished
            )
            #expect(ledger.observe(late) == .unassociated(.timedOut))
            #expect(ledger.state(for: current.id) == .sent)
            #expect(ledger.state(for: turn.id) == .timedOut)
        }
        let live = try ProviderSessionEvent(binding: fixture.binding, sequence: 3, turn: current, kind: .finished)
        #expect(ledger.observe(live) == .associated(current, state: .finished))
    }

    @Test func unassociatedOutputDoesNotCompleteAnyTurn() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        let noTurn = try ProviderSessionEvent(binding: fixture.binding, sequence: 0, kind: .finished)
        #expect(ledger.observe(noTurn) == .unassociated(.noTurn))
        let unknown = try ProviderSessionEvent(
            binding: fixture.binding, sequence: 1, turn: fixture.newTurn(), kind: .finished
        )
        #expect(ledger.observe(unknown) == .unassociated(.unknownTurn))
        #expect(ledger.state(for: fixture.turn.id) == .sent)
    }

    @Test func duplicateAndOutOfOrderEventsCannotAdvanceState() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        let accepted = try fixture.event(0, .accepted)
        #expect(ledger.observe(accepted) == .associated(fixture.turn, state: .accepted))
        #expect(ledger.observe(accepted) == .rejected(.duplicateEvent))
        #expect(ledger.observe(try fixture.event(0, .finished)) == .rejected(.staleSequence))
        #expect(ledger.observe(try fixture.event(2, .finished)) == .rejected(.sequenceGap))
        #expect(ledger.state(for: fixture.turn.id) == .accepted)
        #expect(ledger.observe(try fixture.event(1, .running)) == .associated(fixture.turn, state: .running))
        #expect(ledger.observe(try fixture.event(2, .finished)) == .associated(fixture.turn, state: .finished))
    }

    @Test func repeatedEventIdentityCannotBypassSequenceDedupe() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        let accepted = try fixture.event(0, .accepted)
        _ = ledger.observe(accepted)
        let replay = try ProviderSessionEvent(
            binding: fixture.binding, sequence: 1, turn: fixture.turn, kind: .finished, id: accepted.id
        )
        #expect(ledger.observe(replay) == .rejected(.duplicateEvent))
        #expect(ledger.observe(try fixture.event(1, .running)) == .associated(fixture.turn, state: .running))
    }

    @Test func invalidLifecycleClaimIsVisibleButDoesNotStallStream() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        _ = ledger.observe(try fixture.event(0, .running))
        #expect(ledger.observe(try fixture.event(1, .accepted)) == .rejected(.invalidTransition))
        #expect(ledger.state(for: fixture.turn.id) == .running)
        #expect(ledger.observe(try fixture.event(2, .finished)) == .associated(fixture.turn, state: .finished))
    }

    @Test func failureAndInterruptionAreTerminal() throws {
        for (kind, state) in [(ProviderEventKind.failed(.providerFailed), ProviderTurnState.failed),
                              (.interrupted, .interrupted)] {
            let fixture = try ProviderTestFixture()
            var ledger = try fixture.correlator()
            try ledger.recordSent(fixture.turn)
            #expect(ledger.observe(try fixture.event(0, kind)) == .associated(fixture.turn, state: state))
            #expect(ledger.observe(try fixture.event(1, .finished)) == .rejected(.turnEnded))
            #expect(throws: ProviderContractError.turnEnded) { try ledger.timeOut(fixture.turn.id) }
        }
    }

    @Test func internalTextHasNoImplicitDisplayOrSpeechPromotion() throws {
        let fixture = try ProviderTestFixture()
        var ledger = try fixture.correlator()
        try ledger.recordSent(fixture.turn)
        let internalText = try fixture.event(0, .text("Synthetic internal", isFinal: true, visibility: .internalOnly))
        #expect(ledger.observe(internalText) == .associated(fixture.turn, state: .sent))
        #expect(internalText.kind == .text("Synthetic internal", isFinal: true, visibility: .internalOnly))
    }
}
