import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Real store and playback authorization, with a scripted socket, injected capture clock and silent fake player.
@MainActor
final class ProactiveReceiptCapacityRig {
    let ready: HostConnectionStoreAmbientBindingTests.ReadyStore
    let generation: UUID
    let clock: TestInstantClock
    let player: IdlePlayer
    let playback: ReplyPlaybackController
    var store: HostConnectionStore { ready.store }
    var endpoint: String { ready.endpoint.id }

    static func make() async throws -> ProactiveReceiptCapacityRig {
        let ready = try await HostConnectionStoreAmbientBindingTests().readyStore(capabilities: [
            "ping", "receive_replies", SessionUpdateCard.capability, SessionUpdateCard.audioCapability
        ])
        do {
            ready.store.ambientStreaming = true
            try await ready.socket.push(.targets([
                TargetInfo(id: "tmux:build", kind: "tmux", name: "Build", alive: true)
            ]))
            try await waitUntil { await MainActor.run { ready.store.snapshots[ready.endpoint.id]?.targets.count == 1 } }
            let generation = try #require(ready.store.snapshots[ready.endpoint.id]?.connectionGeneration)
            return try ProactiveReceiptCapacityRig(ready: ready, generation: generation)
        } catch {
            await ready.store.disconnect(ready.endpoint.id)
            throw error
        }
    }

    private init(ready: HostConnectionStoreAmbientBindingTests.ReadyStore, generation: UUID) throws {
        self.ready = ready
        self.generation = generation
        let clock = TestInstantClock()
        self.clock = clock
        let player = IdlePlayer()
        self.player = player
        let playback = ReplyPlaybackController(player: player)
        self.playback = playback
        playback.idleNow = { clock.now() }
        playback.idleScheduler = { _, _ in {} }
        let activity = ProactiveAudioActivity(now: { clock.now() })
        playback.proactive.activity = activity
        playback.proactive.captureSafe = { true }
        try makeQuiet(activity, capture: activity.beginCapture())
        ready.store.wireProactivePlayback(playback)
        ready.store.onReplyFrame = { playback.ingest($0) }
    }

    private func makeQuiet(_ activity: ProactiveAudioActivity, capture: UUID) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<480 { samples[index] = 0 }
        for _ in 0..<60 {
            activity.observe(buffer, capturedAt: clock.now(), capture: capture)
            clock.advance(by: .milliseconds(10))
        }
    }

    func reply() -> ReplyDescriptor {
        let id = UUID()
        return ReplyDescriptor(id: id, hostID: "host", targetID: "tmux:build", audioStreamID: UUID(),
                               priority: .background, sessionUpdateID: id)
    }

    func record(_ descriptor: ReplyDescriptor) {
        let frame = Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID,
            payload: .control(.sessionUpdate(update: descriptor.id, session: "Build", priority: "info",
                                             text: "Synthetic build finished.")))
        HostNoticeOrigin.$generation.withValue(generation) {
            #expect(store.receiveSessionUpdate(HostReplyEvent(endpointID: endpoint, frame: frame)))
        }
    }

    func privacy(_ on: Bool) {
        HostNoticeOrigin.$generation.withValue(generation) {
            #expect(store.receiveAmbientNotice(HostReplyEvent(endpointID: endpoint,
                frame: Frame(timestamp: 2, source: "host", payload: .control(.duckMode(on: on, reason: "device"))))))
        }
    }

    func permits(_ descriptor: ReplyDescriptor) -> Bool {
        store.permitsProactiveSpeech(endpoint, generation: generation, descriptor: descriptor)
    }

    func offerAudio(_ descriptor: ReplyDescriptor, byte: UInt8 = 1) {
        let event = idleAudio(descriptor, sequence: 0, final: true, byte: byte, endpoint: endpoint)
        HostNoticeOrigin.$generation.withValue(generation) {
            #expect(store.receiveSessionUpdateSpeech(event))
            // Also prove the playback controller's installed authorization refuses a directly offered marked frame.
            playback.ingest(event)
        }
    }

    func ordinaryReply() {
        let descriptor = ReplyDescriptor(id: UUID(), hostID: "host", targetID: "tmux:build", audioStreamID: UUID())
        playback.ingest(idleAudio(descriptor, sequence: 0, final: true, byte: 2, endpoint: endpoint))
    }

    func entry(_ descriptor: ReplyDescriptor) -> ConversationEntry? {
        store.conversation.entries.first { $0.id == "\(endpoint)|\(descriptor.id.uuidString.lowercased())" }
    }
}
