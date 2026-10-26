#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct HeardTurnCapabilityTests {
    /// All combinations: heard_turns never substitutes for ambient_heard or request_refusals.
    @Test(arguments: 0..<8) func bothFramesKeepTheirOwnCapabilityGates(_ bits: Int) async throws {
        let heard = bits & 1 != 0, refusals = bits & 2 != 0, turns = bits & 4 != 0
        let capabilities = ["probe"] + (heard ? [AmbientHeard.capability] : [])
            + (refusals ? [RequestRefusals.capability] : []) + (turns ? [HeardTurns.capability] : [])
        let run = try await HeardTurnRig.make(capabilities: capabilities)
        defer { run.pair.close() }
        let request = UUID()
        var turn: UUID?
        if heard {
            turn = try await run.heard(request)
            #expect((turn != nil) == turns)
        } else {
            #expect(await !run.listener.showAmbientHeard(connection: run.connection, target: RecipientTestRig.target,
                                                        text: HeardTurnRig.text, request: request))
            try await run.pair.boundedBarrier(step: "no ambient_heard capability")
        }
        if refusals {
            #expect(try await run.refusal(request) == turn)
        } else {
            #expect(await run.listener.showRouteRefusal(HeardTurnRig.line, target: RecipientTestRig.target,
                                                        connection: run.connection, request: request) == "unsupported")
            try await run.pair.boundedBarrier(step: "no request_refusals capability")
        }
        #expect(await run.listener.heardTurnCount(run.connection) == 0)
        await run.listener.stop(reason: "synthetic test complete")
    }

    @Test func failedQueueRecordsNothingAndAClosedLedgerCannotBeRevived() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: false)
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame(capabilities: HeardTurnRig.capabilities))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let peers = await listener.installFallbackSyntheticPeers([session])
        let peer = try #require(peers.first)
        await peer.stop(reason: "synthetic closed transport")
        let records = HeardTurnRecords()
        #expect(await !peer.postAmbientHeard(HeardTurnRig.text, target: RecipientTestRig.target,
                                             request: UUID(), records: records))
        #expect(records.count == 0)
        records.record(UUID(), turn: UUID())
        #expect(records.count == 1)
        records.close()
        records.record(UUID(), turn: UUID())
        #expect(records.count == 0)
        await listener.stop(reason: "synthetic test complete")
    }
}
#endif
