import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ProviderSessionEventTests {
    @Test func identifiersAreNonblankAndByteBounded() throws {
        for value in ["", " \n", String(repeating: "é", count: 129)] {
            #expect(throws: ProviderContractError.invalidIdentifier) {
                try ProviderSessionBinding(hostID: value, providerID: "fake", targetID: "t", sessionID: "s")
            }
            #expect(throws: ProviderContractError.invalidIdentifier) {
                try ProviderSessionBinding(hostID: "h", providerID: value, targetID: "t", sessionID: "s")
            }
            #expect(throws: ProviderContractError.invalidIdentifier) {
                try ProviderSessionBinding(hostID: "h", providerID: "fake", targetID: value, sessionID: "s")
            }
            #expect(throws: ProviderContractError.invalidIdentifier) {
                try ProviderSessionBinding(hostID: "h", providerID: "fake", targetID: "t", sessionID: value)
            }
        }
        let allowed = String(repeating: "é", count: 128)
        let binding = try ProviderSessionBinding(hostID: allowed, providerID: "fake", targetID: "t", sessionID: "s")
        #expect(binding.hostID.utf8.count == ProviderEventLimits.maxIdentifiers)
    }

    @Test func eventBoundsUseUtf8AndKeepVisibilityExplicit() throws {
        let fixture = try ProviderTestFixture()
        #expect(throws: ProviderContractError.invalidSequence) { try fixture.event(-1, .running) }
        let text = String(repeating: "é", count: 4_096)
        let event = try fixture.event(0, .text(text, isFinal: true, visibility: .internalOnly))
        #expect(event.kind == .text(text, isFinal: true, visibility: .internalOnly))
        #expect(event.turn == fixture.turn)
        #expect(throws: ProviderContractError.oversizedText) {
            try fixture.event(0, .text(text + "x", isFinal: true, visibility: .userVisible))
        }
    }

    @Test func eventsCannotMixBindingAndTurnContext() throws {
        let fixture = try ProviderTestFixture()
        let other = try ProviderTestFixture()
        #expect(throws: ProviderContractError.wrongContext) {
            try ProviderSessionEvent(binding: fixture.binding, sequence: 0, turn: other.turn, kind: .finished)
        }
    }

    @Test func observationIdentityIsNotOnlyADisplayLabel() throws {
        let first = try ProviderTestFixture()
        let restarted = try ProviderSessionBinding(
            hostID: first.binding.hostID, providerID: first.binding.providerID,
            targetID: first.binding.targetID, sessionID: first.binding.sessionID
        )
        #expect(first.binding != restarted)
        #expect(first.binding.observationID != restarted.observationID)
    }
}
