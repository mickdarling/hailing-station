import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ProactiveTargetAvailabilityTests {
    @Test func removedThenRestoredBeforeObserverCannotReviveSpeech() async throws { try await check(dead: false) }
    @Test func deadThenAliveBeforeObserverCannotReviveSpeech() async throws { try await check(dead: true) }

    private func check(dead: Bool) async throws {
        let rig = HostConnectionStoreAmbientBindingTests()
        let ready = try await rig.readyStore(capabilities: [
            "ping", SessionUpdateCard.capability, SessionUpdateCard.audioCapability
        ])
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        store.ambientStreaming = true
        try await socket.push(.targets([TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: true)]))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.targets.count == 1 } }
        let current = try #require(store.snapshots[endpoint.id])
        let id = UUID()
        let descriptor = ReplyDescriptor(id: id, hostID: "host", targetID: "tmux:build", audioStreamID: UUID(),
                                         priority: .background, sessionUpdateID: id)
        HostNoticeOrigin.$generation.withValue(current.connectionGeneration) {
            let card = HostReplyEvent(endpointID: endpoint.id, frame: Frame(timestamp: 1, target: descriptor.targetID,
                source: descriptor.hostID, payload: .control(.sessionUpdate(update: id, session: "Build",
                                                                            priority: "info", text: "Done."))))
            #expect(store.receiveSessionUpdate(card))
            #expect(store.permitsProactiveSpeech(endpoint.id, generation: current.connectionGeneration,
                                                 descriptor: descriptor))
            var unavailable = current
            unavailable.targets = dead ? [TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: false)] : []
            // The exact policy hook called synchronously by receive(snapshot), with no executor hop between edges.
            store.retireUnavailableProactiveTargets(unavailable)
            store.retireUnavailableProactiveTargets(current)
            #expect(!store.permitsProactiveSpeech(endpoint.id, generation: current.connectionGeneration,
                                                  descriptor: descriptor))
            #expect(store.receiveSessionUpdate(card))
            #expect(!store.permitsProactiveSpeech(endpoint.id, generation: current.connectionGeneration,
                                                  descriptor: descriptor))
        }
        await store.disconnect(endpoint.id)
    }
}
