#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct HeardTurnHostTests {
    @Test func legacyFramesStayByteIdenticalAndNeverAcquireRecords() async throws {
        let run = try await HeardTurnRig.make(
            capabilities: ["probe", AmbientHeard.capability, RequestRefusals.capability]
        )
        defer { run.pair.close() }
        let request = UUID()
        #expect(try await run.heard(request) == nil)
        #expect(await run.listener.heardTurnCount(run.connection) == 0)
        #expect(try await run.refusal(request) == nil)
        await run.listener.stop(reason: "synthetic test complete")
    }

    @Test func overlappingIdenticalWordsHaveDistinctRandomTurnsAndMatchingOneShotRefusals() async throws {
        let run = try await HeardTurnRig.make()
        defer { run.pair.close() }
        let (first, second) = (UUID(), UUID())
        let turn1 = try #require(await run.heard(first))
        let turn2 = try #require(await run.heard(second))
        #expect(turn1 != turn2 && turn1 != first && turn2 != second)
        #expect(turn1.uuidString.split(separator: "-")[2].first == "4")
        #expect(turn2.uuidString.split(separator: "-")[2].first == "4")
        #expect(try await run.refusal(UUID()) == nil)
        #expect(try await run.refusal(nil) == nil)
        #expect(try await run.refusal(second) == turn2)
        #expect(try await run.refusal(first) == turn1)
        #expect(try await run.refusal(first) == nil)
        #expect(await run.listener.heardTurnCount(run.connection) == 0)
        #expect(run.log.allDetails.allSatisfy {
            !$0.contains(HeardTurnRig.text) && !$0.contains(turn1.uuidString) && !$0.contains(turn2.uuidString)
        })
        await run.listener.stop(reason: "synthetic test complete")
    }

    @Test func completedAndNeverQueuedRequestsHaveNoTurn() async throws {
        let run = try await HeardTurnRig.make()
        defer { run.pair.close() }
        let request = UUID()
        _ = try #require(await run.heard(request))
        await run.listener.finishHeardRequest(request, connection: run.connection)
        #expect(try await run.refusal(request) == nil)
        for text in ["", String(repeating: "x", count: PayloadLimits.maxTextBytes + 1)] {
            #expect(await !run.listener.showAmbientHeard(connection: run.connection, target: RecipientTestRig.target,
                                                        text: text, request: request))
        }
        #expect(await !run.listener.showAmbientHeard(connection: run.connection, target: "tmux:elsewhere",
                                                    text: HeardTurnRig.text, request: request))
        #expect(await !run.listener.showAmbientHeard(connection: UUID(), target: RecipientTestRig.target,
                                                    text: HeardTurnRig.text, request: request))
        #expect(try await run.refusal(request) == nil)
        #expect(await run.listener.heardTurnCount(run.connection) == 0)
        await run.listener.stop(reason: "synthetic test complete")
    }

    @Test func evictionKeepsOnlyTheNewest64Requests() async throws {
        let run = try await HeardTurnRig.make()
        defer { run.pair.close() }
        let evicted = UUID()
        _ = try #require(await run.heard(evicted))
        var newest: (UUID, UUID)?
        var seen = Set<UUID>()
        for _ in 0..<HeardTurnRecords.capacity + 3 {
            let request = UUID()
            let turn = try #require(await run.heard(request))
            #expect(seen.insert(turn).inserted)
            newest = (request, turn)
            #expect(await run.listener.heardTurnCount(run.connection) <= HeardTurnRecords.capacity)
        }
        #expect(await run.listener.heardTurnCount(run.connection) == HeardTurnRecords.capacity)
        #expect(try await run.refusal(evicted) == nil)
        let (request, turn) = try #require(newest)
        #expect(try await run.refusal(request) == turn)
        #expect(await run.listener.heardTurnCount(run.connection) == HeardTurnRecords.capacity - 1)
        await run.listener.stop(reason: "synthetic test complete")
        #expect(await run.listener.heardTurns.isEmpty)
    }

    @Test func anotherConnectionAndReconnectCannotBorrowOrReuseTurns() async throws {
        let run = try await HeardTurnRig.make()
        defer { run.pair.close() }
        let request = UUID()
        let turnA = try #require(await run.heard(request))
        let other = try await FallbackSocketPair.boundedConnect(
            port: run.port, selecting: [RecipientTestRig.target], capabilities: HeardTurnRig.capabilities
        )
        defer { other.close() }
        let connectionB = try #require(await run.listener.heardTurnConnections().subtracting([run.connection]).first)
        #expect(try await run.refusal(request, connection: connectionB, socket: other.sockets[0]) == nil)
        let turnB = try #require(await run.heard(request, connection: connectionB, socket: other.sockets[0]))
        #expect(turnB != turnA)
        #expect(try await run.refusal(request, connection: connectionB, socket: other.sockets[0]) == turnB)
        run.pair.close()
        #expect(await eventually { await !run.listener.heardTurnConnections().contains(run.connection) })
        #expect(await run.listener.heardTurnCount(run.connection) == 0)
        let reconnected = try await FallbackSocketPair.boundedConnect(
            port: run.port, selecting: [RecipientTestRig.target], capabilities: HeardTurnRig.capabilities
        )
        defer { reconnected.close() }
        let connectionC = try #require(await run.listener.heardTurnConnections().subtracting([connectionB]).first)
        #expect(connectionC != run.connection)
        #expect(try await run.refusal(request, connection: connectionC, socket: reconnected.sockets[0]) == nil)
        let turnC = try #require(await run.heard(request, connection: connectionC, socket: reconnected.sockets[0]))
        #expect(turnC != turnA && turnC != turnB)
        #expect(try await run.refusal(request, connection: connectionC, socket: reconnected.sockets[0]) == turnC)
        await run.listener.stop(reason: "synthetic test complete")
    }
}
#endif
