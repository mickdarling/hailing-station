import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct HostConnectionProactiveSpeechTests {
    private let rig = HostConnectionStoreAmbientBindingTests()

    @Test func actualSocketPairsOneCardWithGatedAudioAndScopedCancellation() async throws {
        let ready = try await ready()
        let (store, socket, endpoint) = (ready.store, ready.socket, ready.endpoint)
        let clock = TestInstantClock()
        let activity = ProactiveAudioActivity(now: { clock.now() })
        let token = activity.beginCapture()
        try quiet(activity, token: token, clock: clock)
        let player = IdlePlayer()
        let playback = ReplyPlaybackController(player: player)
        playback.idleNow = { clock.now() }
        playback.proactive.activity = activity
        playback.proactive.captureSafe = { true }
        store.wireProactivePlayback(playback)
        store.onReplyFrame = { playback.ingest($0) }
        let descriptor = reply()
        try await socket.push(FrameCoding.encode(card(descriptor.id, endpoint: endpoint.id).frame))
        try await socket.push(FrameCoding.encode(idleAudio(descriptor, sequence: 0, final: true,
                                                         byte: 1, endpoint: endpoint.id).frame))
        try await waitUntil { await MainActor.run { player.scheduled.count == 1 } }
        #expect(store.conversation.entries.count == 1 && store.conversation.entries.first?.spoken == true)
        #expect(store.conversation.entries.first?.metadata == "Tests passed.")
        #expect(store.replyFrames.isEmpty)
        let cancel = Frame(timestamp: 2, target: descriptor.targetID, source: descriptor.hostID,
                           payload: .control(.sessionUpdateCancel(update: descriptor.id)))
        try await socket.push(FrameCoding.encode(cancel))
        try await waitUntil { await MainActor.run { player.cancelCount == 1 } }
        #expect(store.conversation.entries.count == 1)
        #expect(playback.queue.isEmpty)
        await store.disconnect(endpoint.id)
    }

    @Test func unknownEvictedOrWrongGenerationReceiptsCannotAuthorizeAudio() async throws {
        let ready = try await ready()
        let (store, endpoint) = (ready.store, ready.endpoint)
        let generation = try #require(store.snapshots[endpoint.id]?.connectionGeneration)
        let descriptor = reply()
        #expect(!store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
        HostNoticeOrigin.$generation.withValue(generation) {
            #expect(store.receiveSessionUpdate(card(descriptor.id, endpoint: endpoint.id)))
        }
        #expect(store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
        #expect(!store.permitsProactiveSpeech(endpoint.id, generation: UUID(), descriptor: descriptor))
        HostNoticeOrigin.$generation.withValue(generation) {
            for _ in 0..<ConversationLog.limit { _ = store.receiveSessionUpdate(card(UUID(), endpoint: endpoint.id)) }
        }
        #expect(store.proactiveSpeechReceipts.count == ConversationLog.limit)
        #expect(!store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
        await store.disconnect(endpoint.id)
    }

    @Test func cancellationNeedsExactCurrentSourceAndTargetAndNeverRenews() async throws {
        let ready = try await ready()
        let (store, endpoint) = (ready.store, ready.endpoint)
        let generation = try #require(store.snapshots[endpoint.id]?.connectionGeneration)
        let descriptor = reply()
        HostNoticeOrigin.$generation.withValue(generation) {
            _ = store.receiveSessionUpdate(card(descriptor.id, endpoint: endpoint.id))
            for (source, target) in [("other", descriptor.targetID), (descriptor.hostID, "other")] {
                let event = HostReplyEvent(endpointID: endpoint.id, frame: Frame(timestamp: 2, target: target,
                    source: source, payload: .control(.sessionUpdateCancel(update: descriptor.id))))
                #expect(store.receiveSessionUpdateSpeech(event))
            }
        }
        #expect(store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
        HostNoticeOrigin.$generation.withValue(generation) {
            let event = HostReplyEvent(endpointID: endpoint.id, frame: Frame(timestamp: 2,
                target: descriptor.targetID, source: descriptor.hostID,
                payload: .control(.sessionUpdateCancel(update: descriptor.id))))
            #expect(store.receiveSessionUpdateSpeech(event))
            _ = store.receiveSessionUpdate(card(descriptor.id, endpoint: endpoint.id))
        }
        #expect(!store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
        #expect(store.conversation.entries.count == 1)
        await store.disconnect(endpoint.id)
    }

    @Test func publicAgainDoesNotReviveAPrivateSpeechReceipt() async throws {
        let ready = try await ready()
        let (store, endpoint, socket) = (ready.store, ready.endpoint, ready.socket)
        let generation = try #require(store.snapshots[endpoint.id]?.connectionGeneration)
        let descriptor = reply()
        let playback = ReplyPlaybackController(player: IdlePlayer())
        store.wireProactivePlayback(playback)
        HostNoticeOrigin.$generation.withValue(generation) {
            _ = store.receiveSessionUpdate(card(descriptor.id, endpoint: endpoint.id))
        }
        try await socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { store.proactiveSpeechReceipts.first?.allowed == false } }
        try await socket.push(.duckMode(on: false, reason: "device"))
        try await waitUntil { await MainActor.run { store.duckMode[endpoint.id]?.on == false } }
        #expect(!store.permitsProactiveSpeech(endpoint.id, generation: generation, descriptor: descriptor))
        await store.disconnect(endpoint.id)
    }

    private func ready() async throws -> HostConnectionStoreAmbientBindingTests.ReadyStore {
        let ready = try await rig.readyStore(capabilities: [
            "ping", "receive_replies", SessionUpdateCard.capability, SessionUpdateCard.audioCapability
        ])
        ready.store.ambientStreaming = true
        try await ready.socket.push(.targets([
            TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: true)
        ]))
        try await waitUntil { await MainActor.run { ready.store.snapshots[ready.endpoint.id]?.targets.count == 1 } }
        return ready
    }

    private func reply() -> ReplyDescriptor {
        let id = UUID()
        return ReplyDescriptor(id: id, hostID: "host", targetID: "tmux:build", audioStreamID: UUID(),
                               priority: .background, sessionUpdateID: id)
    }

    private func card(_ id: UUID, endpoint: String) -> HostReplyEvent {
        HostReplyEvent(endpointID: endpoint, frame: Frame(timestamp: 1, target: "tmux:build", source: "host",
            payload: .control(.sessionUpdate(update: id, session: "Build", priority: "info",
                                             text: "Build passed.", card: "Tests passed."))))
    }

    private func quiet(_ activity: ProactiveAudioActivity, token: UUID, clock: TestInstantClock) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<480 { samples[index] = 0 }
        for _ in 0..<60 {
            activity.observe(buffer, capturedAt: clock.now(), capture: token)
            clock.advance(by: .milliseconds(10))
        }
    }
}
