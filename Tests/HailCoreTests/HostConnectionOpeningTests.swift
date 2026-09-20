import HailCore
import Testing

@Suite struct HostConnectionOpeningTests {
    @Test func foregroundReplacementDrainsSupersededOpenBeforeStartingAnother() async throws {
        let endpoint = try endpoint()
        let superseded = ScriptedSocket()
        let replacement = ScriptedSocket()
        let gate = OpenGate()
        let connector = SuspendingConnector(
            gate: gate, steps: [.socket(superseded), .socket(replacement)]
        )
        let clock = TestInstantClock()
        let deadline = DeadlineGate()
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            negotiationTimeout: .seconds(10),
            negotiationScheduler: { deadline.schedule($0, action: $1) },
            monotonicNow: { clock.now() }
        )

        await connection.connect()
        try await waitUntil { await connector.openCount == 1 }
        clock.advance(by: .seconds(11))
        await connection.foregrounded()
        await connection.foregrounded()
        #expect(await connector.openCount == 1)

        await gate.release()
        try await waitUntil { await connector.openCount == 2 }
        try await waitUntil { await superseded.closeCount == 1 }

        #expect(await connector.maximumActiveOpenCount == 1)
        #expect(await replacement.closeCount == 0)
        #expect(await connection.currentSnapshot().state == .negotiating)
        await connection.disconnect()
    }

    @Test func foregroundReplacementWaitsForSupersededOpenFailure() async throws {
        let endpoint = try endpoint()
        let replacement = ScriptedSocket()
        let gate = OpenGate()
        let connector = SuspendingConnector(gate: gate, steps: [.failure, .socket(replacement)])
        let clock = TestInstantClock()
        let deadline = DeadlineGate()
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            negotiationTimeout: .seconds(10),
            negotiationScheduler: { deadline.schedule($0, action: $1) },
            monotonicNow: { clock.now() }
        )

        await connection.connect()
        try await waitUntil { await connector.openCount == 1 }
        clock.advance(by: .seconds(11))
        await connection.foregrounded()
        await gate.release()
        try await waitUntil { await connector.openCount == 2 }

        #expect(await connector.maximumActiveOpenCount == 1)
        #expect(await replacement.closeCount == 0)
        #expect(await connection.currentSnapshot().state == .negotiating)
        await connection.disconnect()
    }

    @Test func replacementDoesNotWaitForClosedReceiveToFinish() async throws {
        let endpoint = try endpoint()
        let lingering = ScriptedSocket(finishReceiveOnClose: false)
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        let deadline = SleepGate()
        await connector.enqueue(.socket(lingering), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            deadlineSleep: { try await deadline.sleep($0) }
        )

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await lingering.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        await connection.foregrounded()
        try await waitUntil { await deadline.isWaiting() }
        await deadline.fire()
        try await waitUntil { try await replacement.sentFrames().count == 1 }

        #expect(await lingering.closeCount == 1)
        #expect(await connection.currentSnapshot().state == .negotiating)
        try await lingering.push(.error(code: .malformed, message: "stale"))
        await connection.disconnect()
    }

    @Test func replacementWaitsForInstalledTransportClose() async throws {
        let endpoint = try endpoint()
        let initial = ScriptedSocket()
        let closeGate = OpenGate()
        let slowClose = CloseSuspendingSocket(base: initial, gate: closeGate)
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        let deadline = SleepGate()
        await connector.enqueue(.socket(slowClose), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            deadlineSleep: { try await deadline.sleep($0) }
        )

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await initial.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        await connection.foregrounded()
        try await waitUntil { await deadline.isWaiting() }
        await deadline.fire()
        try await waitUntil { await slowClose.closeStarted }
        #expect(await connector.openCount(for: endpoint.url) == 1)

        await closeGate.release()
        try await waitUntil { try await replacement.sentFrames().count == 1 }
        #expect(await connector.openCount(for: endpoint.url) == 2)
        await connection.disconnect()
    }

    @Test func reconnectDuringDisconnectHandoffIsNotDropped() async throws {
        let endpoint = try endpoint()
        let superseded = ScriptedSocket()
        let replacement = ScriptedSocket()
        let gate = OpenGate()
        let connector = SuspendingConnector(
            gate: gate, steps: [.socket(superseded), .socket(replacement)]
        )
        let connection = HostConnection(endpoint: endpoint, connector: connector)

        await connection.connect()
        try await waitUntil { await connector.openCount == 1 }
        let disconnect = Task { await connection.disconnect() }
        try await waitUntil { await connection.currentSnapshot().state == .disconnected }
        await connection.connect()
        #expect(await connector.openCount == 1)

        await gate.release()
        await disconnect.value
        try await waitUntil { await connector.openCount == 2 }
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        #expect(await superseded.closeCount == 1)
        await connection.disconnect()
    }
}
