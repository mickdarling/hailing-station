import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ProactivePolicyTransitionTests {
    private enum Mode: Equatable { case privacy, media, stop, startAfterCard }
    @Test func aSameExecutorPrivateOnOffBurstNeverRevivesOldAudio() async throws {
        try await checkBurst(mode: .privacy)
    }

    @Test func aSameExecutorMediaOnOffBurstNeverRevivesOldAudio() async throws {
        try await checkBurst(mode: .media)
    }

    @Test func aSameExecutorStopStartBurstNeverRevivesOldAudio() async throws {
        try await checkBurst(mode: .stop)
    }

    @Test func aCardReceivedWhileStoppedCannotGainSpeechAuthorityWhenListeningStarts() async throws {
        try await checkBurst(mode: .startAfterCard)
    }

    private func checkBurst(mode: Mode) async throws {
        let rig = HostConnectionStoreAmbientBindingTests()
        let ready = try await rig.readyStore(capabilities: [
            "ping", SessionUpdateCard.capability, SessionUpdateCard.audioCapability
        ])
        let (store, socket, endpoint) = (ready.store, ready.socket, ready.endpoint)
        store.ambientStreaming = mode != .startAfterCard
        try await socket.push(.targets([TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: true)]))
        try await waitUntil { await MainActor.run { store.snapshots[endpoint.id]?.targets.count == 1 } }
        let generation = try #require(store.snapshots[endpoint.id]?.connectionGeneration)
        let id = UUID()
        let descriptor = ReplyDescriptor(id: id, hostID: "host", targetID: "tmux:build", audioStreamID: UUID(),
                                         priority: .background, sessionUpdateID: id)
        let card = HostReplyEvent(endpointID: endpoint.id, frame: Frame(timestamp: 1, target: descriptor.targetID,
            source: descriptor.hostID, payload: .control(.sessionUpdate(update: id, session: "Build", priority: "info",
                                                                        text: "Done."))))
        HostNoticeOrigin.$generation.withValue(generation) {
            #expect(store.receiveSessionUpdate(card))
            #expect(store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor)
                    == (mode != .startAfterCard))
            // No executor hop, sleep or observation callback between the edges.
            for on in [true, false] {
                switch mode {
                case .stop: store.ambientStreaming = !on
                case .startAfterCard: store.ambientStreaming = true
                case .privacy, .media:
                    let control: ControlPayload = mode == .privacy ? .duckMode(on: on, reason: "device")
                        : .mediaMode(on: on, reason: "voice")
                    #expect(store.receiveAmbientNotice(HostReplyEvent(endpointID: endpoint.id,
                        frame: Frame(timestamp: 2, source: "host", payload: .control(control)))))
                }
            }
            #expect(!store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
            #expect(store.receiveSessionUpdate(card))
            #expect(!store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
        }
        #expect(store.conversation.entries.count == 1)
        await store.disconnect(endpoint.id)
    }
}
