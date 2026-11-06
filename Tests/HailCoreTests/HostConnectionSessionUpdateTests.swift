import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct HostConnectionSessionUpdateTests {
    private let rig = HostConnectionStoreAmbientBindingTests()

    private func event(endpoint: String, target: String? = "tmux:build", update: UUID = UUID()) -> HostReplyEvent {
        HostReplyEvent(endpointID: endpoint, frame: Frame(timestamp: 1, target: target, source: "host",
            payload: .control(.sessionUpdate(update: update, session: "Build", priority: "action",
                                             text: "Build passed.", card: "Tests passed."))))
    }

    private func ready() async throws -> HostConnectionStoreAmbientBindingTests.ReadyStore {
        let ready = try await rig.readyStore(capabilities: [
            "ping", SessionUpdateCard.capability, DuckMode.privacySwitchCapability
        ])
        try await ready.socket.push(.targets([
            TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: true)
        ]))
        try await waitUntil { await MainActor.run { ready.store.snapshots[ready.endpoint.id]?.targets.count == 1 } }
        return ready
    }

    @Test func capableSocketDeliversOneCardAndNeverTouchesPlaybackIngress() async throws {
        let ready = try await ready()
        let (store, socket, endpoint) = (ready.store, ready.socket, ready.endpoint)
        let hello = try #require(try await socket.sentFrames().first)
        guard case .control(.hello(let info)) = hello.payload else { Issue.record("expected hello"); return }
        #expect(info.capabilities.contains(SessionUpdateCard.capability))
        var played = 0
        store.onReplyFrame = { _ in played += 1 }
        let update = event(endpoint: endpoint.id)
        try await socket.push(FrameCoding.encode(update.frame))
        try await socket.push(FrameCoding.encode(update.frame))
        try await socket.push(.targets([])) // Receive-loop barrier behind both cards.
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.targets.isEmpty == true } }
        #expect(store.conversation.entries.count == 1)
        #expect(store.conversation.entries.first?.source == "Build")
        #expect(store.replyFrames.isEmpty && played == 0)
        #expect(store.snapshots[endpoint.id]?.state == .ready)
        await store.disconnect(endpoint.id)
    }

    @Test func currentGenerationReadyCapabilityAndExactListedTargetAreRequired() async throws {
        let ready = try await ready()
        let (store, endpoint) = (ready.store, ready.endpoint)
        let generation = try #require(store.snapshots[endpoint.id]?.connectionGeneration)
        let update = event(endpoint: endpoint.id)
        #expect(store.receiveSessionUpdate(update)) // No provenance: inert.
        HostNoticeOrigin.$generation.withValue(UUID()) { #expect(store.receiveSessionUpdate(update)) }
        HostNoticeOrigin.$generation.withValue(generation) {
            #expect(store.receiveSessionUpdate(event(endpoint: endpoint.id, target: "unlisted")))
            #expect(store.receiveSessionUpdate(event(endpoint: endpoint.id, target: nil)))
        }
        #expect(store.conversation.entries.isEmpty)
        await store.disconnect(endpoint.id)
        HostNoticeOrigin.$generation.withValue(generation) { #expect(store.receiveSessionUpdate(update)) }
        #expect(store.conversation.entries.isEmpty)
    }

    @Test func privateCardsAreDroppedAndDuplicateAfterPublicIsNotMarkedReceived() async throws {
        let ready = try await ready()
        let (store, socket, endpoint) = (ready.store, ready.socket, ready.endpoint)
        let update = event(endpoint: endpoint.id)
        try await socket.push(.duckMode(on: true, reason: "device"))
        try await socket.push(FrameCoding.encode(update.frame))
        try await socket.push(.duckMode(on: false, reason: "device"))
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == false } }
        #expect(store.conversation.entries.isEmpty)
        try await socket.push(FrameCoding.encode(update.frame))
        try await waitUntil { await MainActor.run { store.conversation.entries.count == 1 } }
        await store.disconnect(endpoint.id)
    }

    @Test func pendingPrivacyOnSuppressesCardsBeforeHostConfirmation() async throws {
        let ready = try await ready()
        let (store, socket, endpoint) = (ready.store, ready.socket, ready.endpoint)
        await socket.holdSends()
        let request = Task { try await store.setPrivacy(on: true, host: endpoint.id) }
        try await waitUntil {
            try await socket.sentFrames().contains { $0.payload == .control(.setPrivacy(on: true)) }
        }
        try await socket.push(FrameCoding.encode(event(endpoint: endpoint.id).frame))
        try await socket.push(.mediaMode(on: true, reason: "voice"))
        try await waitUntil { await MainActor.run { store.mediaMode[endpoint.id]?.on == true } }
        #expect(store.conversation.entries.isEmpty)
        await socket.releaseSends()
        try await request.value
        await store.disconnect(endpoint.id)
    }

    @Test func unnegotiatedUpdatesFailClosed() async throws {
        let ready = try await rig.readyStore(capabilities: ["ping"])
        try await ready.socket.push(FrameCoding.encode(event(endpoint: ready.endpoint.id).frame))
        try await waitUntil {
            await MainActor.run {
                if case .failed = ready.store.snapshots[ready.endpoint.id]?.state { return true }
                return false
            }
        }
        #expect(ready.store.conversation.entries.isEmpty)
        await ready.store.disconnect(ready.endpoint.id)
    }
}
