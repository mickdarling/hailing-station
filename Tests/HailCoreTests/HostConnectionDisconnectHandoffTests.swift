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
        let returned = CompletionFlag()

        await connection.connect()
        try await waitUntil { await connector.openCount == 1 }
        let disconnect = Task {
            await connection.disconnect()
            await returned.set()
        }
        do {
            try await waitUntil(timeout: .milliseconds(100)) { await returned.isSet }
        } catch {
            await gate.release()
            await disconnect.value
            throw error
        }

        #expect(await connection.currentSnapshot().state == .disconnected)
        await gate.release()
        await disconnect.value
        try await waitUntil { await superseded.closeCount == 1 }
    }
}
