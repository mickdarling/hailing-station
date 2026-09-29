import Foundation
@testable import HailDaemonKit

/// Invented labels/text only; this rig observes no application or microphone.
struct ProviderTestFixture {
    let binding: ProviderSessionBinding
    let connectionID = UUID()
    let turn: ProviderTurnContext

    init() throws {
        binding = try ProviderSessionBinding(
            hostID: "host-test", providerID: "synthetic", targetID: "test:target", sessionID: "session-test"
        )
        turn = ProviderTurnContext(utteranceID: UUID(), connectionID: connectionID, binding: binding)
    }

    func correlator(maxTurns: Int = 128, maxEvents: Int = 4_096) throws -> ProviderTurnCorrelator {
        try ProviderTurnCorrelator(
            binding: binding, connectionID: connectionID, maxTurns: maxTurns, maxEvents: maxEvents
        )
    }

    func event(_ sequence: Int, _ kind: ProviderEventKind) throws -> ProviderSessionEvent {
        try ProviderSessionEvent(binding: binding, sequence: sequence, turn: turn, kind: kind)
    }

    func newTurn() -> ProviderTurnContext {
        ProviderTurnContext(utteranceID: UUID(), connectionID: connectionID, binding: binding)
    }
}
