import HailCore
import Testing

@MainActor
@Suite struct HostConnectionStoreHandoffTests {
    @Test func replacementActorInheritsInstalledSocketCloseBarrier() async throws {
        let original = try endpoint("stable-id", "ws://127.0.0.1:8765")
        let renamed = try HostEndpoint(id: original.id, name: "renamed", url: original.url)
        let renamedAgain = try HostEndpoint(id: original.id, name: "renamed again", url: original.url)
        let initial = ScriptedSocket()
        let closeGate = OpenGate()
        let slowClose = CloseSuspendingSocket(base: initial, gate: closeGate)
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(slowClose), for: original.url)
        await connector.enqueue(.socket(replacement), for: original.url)
        let store = HostConnectionStore(connector: connector)
        let upsertReturned = CompletionFlag()

        await store.upsert(original)
        await store.connect(original.id)
        try await waitUntil { try await initial.sentFrames().count == 1 }
        try await initial.push(hostHello())
        try await waitUntil {
            await MainActor.run { store.snapshots[original.id]?.state == .ready }
        }

        let upsert = Task { @MainActor in
            await store.upsert(renamed)
            await upsertReturned.set()
        }
        try await waitUntil { await slowClose.closeStarted }
        try await waitUntil(timeout: .milliseconds(100)) { await upsertReturned.isSet }
        await store.upsert(renamedAgain)
        await store.connect(renamedAgain.id)
        #expect(await connector.openCount(for: original.url) == 1)

        await closeGate.release()
        await upsert.value
        try await waitUntil { try await replacement.sentFrames().count == 1 }
        #expect(await connector.openCount(for: original.url) == 2)
        await store.disconnect(renamed.id)
    }

    @Test func readdedHostInheritsRemovedActorsCloseBarrier() async throws {
        let original = try endpoint("stable-id", "ws://127.0.0.1:8765")
        let readded = try HostEndpoint(id: original.id, name: "readded", url: original.url)
        let initial = ScriptedSocket()
        let closeGate = OpenGate()
        let slowClose = CloseSuspendingSocket(base: initial, gate: closeGate)
        let replacement = ScriptedSocket()
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(slowClose), for: original.url)
        await connector.enqueue(.socket(replacement), for: original.url)
        let store = HostConnectionStore(connector: connector)

        await store.upsert(original)
        await store.connect(original.id)
        try await waitUntil { try await initial.sentFrames().count == 1 }
        try await initial.push(hostHello())
        try await waitUntil {
            await MainActor.run { store.snapshots[original.id]?.state == .ready }
        }

        await store.remove(original.id)
        try await waitUntil { await slowClose.closeStarted }
        await store.upsert(readded)
        await store.connect(readded.id)
        #expect(await connector.openCount(for: original.url) == 1)

        await closeGate.release()
        try await waitUntil { try await replacement.sentFrames().count == 1 }
        #expect(await connector.openCount(for: original.url) == 2)
        await store.disconnect(readded.id)
    }
}
