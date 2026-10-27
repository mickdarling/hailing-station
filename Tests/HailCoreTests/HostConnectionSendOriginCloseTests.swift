import Foundation
import Testing
@testable import HailCore

@Suite struct HostConnectionSendOriginCloseTests {
    @Test func absentLossHookPreservesCloseBeforeReconnectPublication() async throws {
        let endpoint = try endpoint()
        let connector = ScriptedConnector()
        let base = ScriptedSocket()
        let gate = OpenGate()
        let closing = CloseSuspendingSocket(base: base, gate: gate)
        let snapshots = SnapshotRecorder()
        let retry = SleepGate()
        await connector.enqueue(.socket(closing), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint, connector: connector,
            deadlineSleep: { _ in throw CancellationError() },
            sleep: { try await retry.sleep($0) }, observer: { await snapshots.append($0) }
        )
        await connection.connect()
        try await awaitHello(connection, base, capabilities: ["ping"])
        let states = await snapshots.states()
        let generation = await connection.currentSnapshot().connectionGeneration
        await base.fail()
        try await waitUntil { await closing.closeStarted }
        #expect(await connection.currentSnapshot().state == .ready)
        #expect(await connection.currentSnapshot().connectionGeneration == generation)
        #expect(await snapshots.states() == states)
        #expect(await retry.isWaiting() == false)
        #expect(await closing.closeStartCount == 1)
        await gate.release()
        try await waitUntil { await retry.isWaiting() }
        let after = await snapshots.states()
        #expect(Array(after.dropLast()) == states)
        guard case .reconnecting = after.last else {
            Issue.record("Close completion must precede reconnect publication")
            await connection.disconnect()
            await retry.fire()
            return
        }
        await connection.disconnect()
        await retry.fire()
    }

    @Test func optedInLossReportsLostGenerationBeforeCloseOrStatePublication() async throws {
        let endpoint = try endpoint()
        let connector = ScriptedConnector()
        let base = ScriptedSocket()
        let gate = OpenGate()
        let closing = CloseSuspendingSocket(base: base, gate: gate)
        let losses = SendOriginLossRecorder()
        let snapshots = SnapshotRecorder()
        let retry = SleepGate()
        await connector.enqueue(.socket(closing), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint, connector: connector,
            deadlineSleep: { _ in throw CancellationError() },
            transportLossObserver: { generation, sending in
                await losses.append(generation, sending: sending, closeStarted: closing.closeStarted)
            }, sleep: { try await retry.sleep($0) }, observer: { await snapshots.append($0) }
        )
        await connection.connect()
        try await awaitHello(connection, base, capabilities: ["ping"])
        let states = await snapshots.states()
        let generation = await connection.currentSnapshot().connectionGeneration
        await base.fail()
        try await waitUntil { await closing.closeStarted }
        #expect(await losses.generations == [generation])
        #expect(await losses.sends == [false])
        #expect(await losses.closes == [false])
        #expect(await snapshots.states() == states)
        await gate.release()
        try await waitUntil { await retry.isWaiting() }
        await connection.disconnect()
        await retry.fire()
    }
}

private actor SendOriginLossRecorder {
    var generations: [UUID] = []
    var sends: [Bool] = []
    var closes: [Bool] = []
    func append(_ generation: UUID, sending: Bool, closeStarted: Bool) {
        generations.append(generation)
        sends.append(sending)
        closes.append(closeStarted)
    }
}
