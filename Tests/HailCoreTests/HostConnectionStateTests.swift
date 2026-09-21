import HailCore
import Testing

@Suite(.serialized) struct HostConnectionStateTests {
    @Test func transportFailureReconnectsThroughLegalStatesAndRemoteCloseRetries() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let replacementSocket = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.failure, for: endpoint.url)
        await connector.enqueue(.socket(socket), for: endpoint.url)
        await connector.enqueue(.socket(replacementSocket), for: endpoint.url)
        let snapshots = SnapshotRecorder()
        let sleeps = SleepRecorder()
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            sleep: { await sleeps.sleep($0) },
            jitter: { 0.5 },
            observer: { await snapshots.append($0) }
        )

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        let readyGeneration = await connection.currentSnapshot().connectionGeneration
        await socket.fail()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }

        let states = await snapshots.states()
        #expect(states.starts(with: initialReconnectStates))
        let reconnects = states.filter { if case .reconnecting = $0 { true } else { false } }
        #expect(reconnects == [.reconnecting(attempt: 1, nextDelay: 1), .reconnecting(attempt: 1, nextDelay: 1)])
        #expect(await sleeps.durations == [.seconds(1), .seconds(1)])
        #expect(await connection.currentSnapshot().connectionGeneration > readyGeneration)
        await connection.disconnect()
        #expect(await connection.currentSnapshot().state == .disconnected)
    }

    @Test func manualDisconnectCancelsReconnectAndForegroundDoesNotCreateASocket() async throws {
        let endpoint = try endpoint()
        let connector = ScriptedConnector()
        await connector.enqueue(.failure, for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint, connector: connector,
            sleep: { _ in try await Task.sleep(for: .seconds(30)) }, jitter: { 0.5 }
        )
        await connection.connect()
        try await waitUntil {
            if case .reconnecting = await connection.currentSnapshot().state { return true }
            return false
        }
        await connection.disconnect()
        await connection.foregrounded()
        #expect(await connection.currentSnapshot().state == .disconnected)
        #expect(await connector.openCount(for: endpoint.url) == 1)
    }

    @Test func stalledHostHelloClosesExactSocketAndUsesBoundedReconnect() async throws {
        let endpoint = try endpoint()
        let stalled = ScriptedSocket()
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        let reconnectSleeps = SleepRecorder()
        let deadline = DeadlineGate()
        await connector.enqueue(.socket(stalled), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            negotiationScheduler: { deadline.schedule($0, action: $1) },
            sleep: { await reconnectSleeps.sleep($0) },
            jitter: { 0.5 }
        )

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        deadline.fire()
        try await waitUntil { try await replacement.sentFrames().count == 1 }

        #expect(await stalled.closeCount == 1)
        #expect(await connector.openCount(for: endpoint.url) == 2)
        #expect(await reconnectSleeps.durations == [.seconds(1)])
        #expect(await connection.currentSnapshot().state == .negotiating)
        await connection.disconnect()
    }

    @Test func foregroundReplacesNegotiationOlderThanHealthDeadline() async throws {
        let endpoint = try endpoint()
        let stale = ScriptedSocket()
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        let clock = TestInstantClock()
        let deadline = DeadlineGate()
        await connector.enqueue(.socket(stale), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            negotiationTimeout: .seconds(10),
            negotiationScheduler: { deadline.schedule($0, action: $1) },
            monotonicNow: { clock.now() }
        )

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        clock.advance(by: .seconds(11))
        await connection.foregrounded()
        try await waitUntil { try await replacement.sentFrames().count == 1 }

        #expect(await stale.closeCount == 1)
        #expect(await connector.openCount(for: endpoint.url) == 2)
        #expect(await connection.currentSnapshot().state == .negotiating)
        await connection.disconnect()
    }

    @Test func staleDeadlineCannotCloseLaterNegotiationWithReusedAttempt() async throws {
        let endpoint = try endpoint()
        let initial = ScriptedSocket()
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        let deadline = DeadlineGate()
        await connector.enqueue(.socket(initial), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            negotiationScheduler: { deadline.schedule($0, action: $1) },
            sleep: { _ in },
            jitter: { 0.5 }
        )

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await initial.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        await initial.fail()
        try await waitUntil { try await replacement.sentFrames().count == 1 }
        deadline.fire()
        try await Task.sleep(for: .milliseconds(10))

        await expectReplacementStillNegotiating(replacement, connector, connection, endpoint)
        await connection.disconnect()
    }

    @Test func manualDisconnectCancelsNegotiationDeadlineWithoutReconnect() async throws {
        let endpoint = try endpoint()
        let stalled = ScriptedSocket()
        let connector = ScriptedConnector()
        let deadline = DeadlineGate()
        await connector.enqueue(.socket(stalled), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connector,
            negotiationScheduler: { deadline.schedule($0, action: $1) }
        )

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        await connection.disconnect()
        deadline.fire()
        try await Task.sleep(for: .milliseconds(10))

        #expect(await connection.currentSnapshot().state == .disconnected)
        #expect(await connector.openCount(for: endpoint.url) == 1)
        #expect(await stalled.closeCount == 1)
    }
}

private let initialReconnectStates: [HostConnectionState] = [
    .connecting, .reconnecting(attempt: 1, nextDelay: 1), .connecting, .negotiating, .ready
]

private func expectReplacementStillNegotiating(
    _ socket: ScriptedSocket, _ connector: ScriptedConnector,
    _ connection: HostConnection, _ endpoint: HostEndpoint
) async {
    #expect(await socket.closeCount == 0)
    #expect(await connector.openCount(for: endpoint.url) == 2)
    #expect(await connection.currentSnapshot().state == .negotiating)
}
