import Foundation
import HailCore
import Testing

@Suite struct HostConnectionDisconnectHandoffTests {
    @Test func disconnectDuringFailedCloseDoesNotRecaptureOrEraseReplacement() async throws {
        let endpoint = try endpoint()
        let initial = ScriptedSocket()
        let closeGate = OpenGate()
        let slowClose = CloseSuspendingSocket(base: initial, gate: closeGate)
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(slowClose), for: endpoint.url)
        await connector.enqueue(.socket(replacement), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector)

        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await initial.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        await initial.fail()
        try await waitUntil { await slowClose.closeStarted }

        let disconnect = Task { await connection.disconnect() }
        try await waitUntil { await connection.currentSnapshot().state == .disconnected }
        await connection.connect()
        #expect(await slowClose.closeStartCount == 1)

        await closeGate.release()
        await disconnect.value
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await replacement.push(hostHello())
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        #expect(await connector.openCount(for: endpoint.url) == 2)
        await connection.disconnect()
    }

    @Test func disconnectReturnsWhileCancellationInsensitiveOpenDrains() async throws {
        let endpoint = try endpoint()
        let superseded = ScriptedSocket()
        let gate = OpenGate()
        let connector = SuspendingConnector(gate: gate, steps: [.socket(superseded)])
        let connection = HostConnection(endpoint: endpoint, connector: connector)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            Issue.record("held-open disconnect fixture stalled; watchdog released gate")
            await gate.release()
        }
        do {
            await connection.connect()
            try await waitUntil { await connector.openCount == 1 }
            let disconnect = Task { await connection.disconnect() }
            await disconnect.value // The open gate stays closed until actual completion.
            #expect(await connection.currentSnapshot().state == .disconnected)
            #expect(await connector.activeOpenCount == 1)
            #expect(await superseded.closeCount == 0)
            await gate.release()
            try await waitUntil {
                let active = await connector.activeOpenCount
                let closes = await superseded.closeCount
                return active == 0 && closes == 1
            }
            #expect(await superseded.closeCount == 1)
            watchdog.cancel(); await watchdog.value
        } catch {
            let original = error
            await gate.release()
            await connection.disconnect()
            watchdog.cancel(); await watchdog.value
            do { try await waitUntil { await connector.activeOpenCount == 0 } } catch {
                Issue.record("held-open cleanup did not drain after gate release")
            }
            throw original
        }
    }
}
