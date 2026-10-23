import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #825 / #850: the card's binding-change and disappearance paths stop ambient capture, not reply playback.
/// Real store/controller wiring with scripted sockets and capture; no microphone or physical output proof.
@MainActor
@Suite struct ReplyPlaybackFirstAudioBindingChangeTests {
    @Test(arguments: [false, true], [false, true])
    func ambientStopPreservesOneLossAcrossReconnect(cardDisappears: Bool, lateAudio: Bool) async throws {
        let harness = try BindingChangeRig(), reply = idleReply()
        let ready = try await harness.connect()
        try await HostConnectionStoreAmbientBindingTests().select(reply.targetID, on: ready)
        let binding = try #require(harness.store.ambientBinding(host: harness.host.id, targetID: reply.targetID))
        await harness.ambient.turnOn(for: binding)
        #expect(harness.ambient.isListening && harness.store.ambientStreaming)
        let original = firstAudioText(reply)
        try await ready.socket.push(FrameCoding.encode(original.frame))
        try await waitUntil { await MainActor.run { harness.playback.liveDeadlineCount == 1 } }
        #expect(harness.playback.status(of: reply) == "Received")
        harness.playback.advance(by: .seconds(10))

        try await stopAmbient(harness, ready: ready, reply: reply, cardDisappears: cardDisappears)
        #expect(!harness.ambient.isOn && !harness.store.ambientStreaming)
        #expect(harness.capture.stopCount > 0)
        #expect(harness.released == 1)
        #expect(harness.stops.count == 1 && harness.stops.first == harness.ambient.stopReason)
        #expect(!harness.playback.controller.isCaptureSuppressed)
        #expect(harness.playback.player.cancelCount == 0)
        #expect(harness.playback.liveDeadlineCount == 1, "ambient stop must not cancel first-audio arrival")
        harness.playback.advance(by: .seconds(9))
        #expect(harness.playback.abandoned == 0 && harness.renderer.rendered.isEmpty)
        harness.playback.advance(by: .seconds(1))
        try await waitUntil { await MainActor.run { harness.playback.player.scheduled.count == 1 } }
        expectOneLossAndCue(harness, reply: reply)
        harness.playback.player.completeReply()

        await harness.store.disconnect(harness.host.id)
        let reconnected = try await harness.connect()
        try await HostConnectionStoreAmbientBindingTests().select(reply.targetID, on: reconnected)
        let renewed = try #require(harness.store.ambientBinding(host: harness.host.id, targetID: reply.targetID))
        #expect(renewed.connectionGeneration != binding.connectionGeneration)
        try await redeliver(harness, ready: reconnected, original: original, reply: reply, lateAudio: lateAudio)
        harness.playback.advance(by: .seconds(60))
        await settleFirstAudio()
        expectOneLossAndCue(harness, reply: reply)
        #expect(harness.playback.liveDeadlineCount == 0)
        await harness.store.disconnect(harness.host.id)
    }

    private func stopAmbient(
        _ harness: BindingChangeRig, ready: HostConnectionStoreAmbientBindingTests.ReadyStore,
        reply: ReplyDescriptor, cardDisappears: Bool
    ) async throws {
        if cardDisappears {
            await harness.store.disconnect(harness.host.id)
            #expect(harness.store.ambientBinding(host: harness.host.id, targetID: reply.targetID) == nil)
            // AmbientListeningCard.onDisappear clears the flag, then calls destinationLost().
            harness.store.ambientStreaming = false
            await harness.ambient.destinationLost()
        } else {
            // Even reselecting the same target changes the store's binding selection serial.
            try await HostConnectionStoreAmbientBindingTests().select(reply.targetID, on: ready)
            let changed = try #require(harness.store.ambientBinding(host: harness.host.id, targetID: reply.targetID))
            #expect(changed != harness.ambient.binding)
            // AmbientListeningCard.onChange(of: binding) forwards the new binding this way.
            await harness.ambient.update(binding: changed, scene: .active)
        }
    }

    private func redeliver(
        _ harness: BindingChangeRig, ready: HostConnectionStoreAmbientBindingTests.ReadyStore,
        original: HostReplyEvent, reply: ReplyDescriptor, lateAudio: Bool
    ) async throws {
        let repeated = firstAudioText(reply)
        #expect(repeated.frame.id != original.frame.id, "deduplicate reply identity, not just frame identity")
        try await ready.socket.push(FrameCoding.encode(repeated.frame))
        try await waitUntil {
            await MainActor.run { harness.store.replyFrames.contains { $0.frame.id == repeated.frame.id } }
        }
        #expect(harness.playback.liveDeadlineCount == 0, "re-sent text must not re-arm a completed loss")
        if lateAudio {
            let audio = idleAudio(reply, sequence: 0, final: true, byte: 7)
            try await ready.socket.push(FrameCoding.encode(audio.frame))
            try await waitUntil {
                await MainActor.run { harness.store.replyFrames.contains { $0.frame.id == audio.frame.id } }
            }
        }
    }

    private func expectOneLossAndCue(_ harness: BindingChangeRig, reply: ReplyDescriptor) {
        let playback = harness.playback
        #expect(playback.abandoned == 1)
        #expect(playback.controller.replies.count == 1)
        #expect(playback.status(of: reply) == ReplyPlaybackController.abandonedStatus)
        #expect(Array(playback.controller.lostAudioStatuses.values) == [ReplyPlaybackController.abandonedStatus])
        #expect(playback.controller.replies.allSatisfy {
            playback.controller.audioProblem(replyID: $0.id) == ReplyPlaybackController.audioDidNotArrive
        })
        #expect(harness.renderer.rendered == [.replyAudioLost])
        #expect(harness.fallbacks.announcements.isEmpty)
        #expect(playback.player.scheduled.count == 1, "only the local Announcer cue reaches the player")
        #expect(playback.player.scheduled.allSatisfy { $0.reply == nil && $0.isFinal && $0.bytes == Data([1, 0]) })
    }
}

@MainActor
private final class BindingChangeRig {
    let playback = IdleRig()
    let renderer = CountingRenderer()
    let fallbacks = FirstAudioFallbacks()
    let capture = FakeAudioCapture()
    let connector = ScriptedConnector()
    let host: HostEndpoint
    let store: HostConnectionStore
    let announcer: Announcer
    var released = 0
    var stops: [String] = []
    lazy var ambient = AmbientListeningController(
        requestPermission: { true },
        makeStreamer: { [capture] send in AmbientAudioStreamer(capture: capture, send: send) },
        releaseSession: { [weak self] in self?.released += 1 },
        send: { [store] payload, binding in try await store.sendAudio(payload, to: binding) }
    )

    init() throws {
        host = try endpoint("main")
        store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        announcer = Announcer(playback: playback.controller, renderer: renderer) { [fallbacks] in
            fallbacks.record($0, $1)
        }
        announcer.watchReplyAudio { true }
        // RootView.task and AmbientListeningCard.init: no stopPlayback, reset or suppression calls.
        store.onReplyFrame = { [playback] in playback.controller.ingest($0) }
        ambient.onListeningChange = { [store] in store.ambientStreaming = $0 }
        ambient.onUnexpectedStop = { [weak self] in self?.stops.append($0) }
    }

    func connect() async throws -> HostConnectionStoreAmbientBindingTests.ReadyStore {
        let socket = ScriptedSocket()
        await connector.enqueue(.socket(socket), for: host.url)
        await store.upsert(host)
        await store.connect(host.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current],
            capabilities: ["ping", "select_target", "stream_audio", "receive_replies"], deviceName: "Mac"
        )))
        try await waitUntil { await MainActor.run { self.store.snapshots[self.host.id]?.state == .ready } }
        return HostConnectionStoreAmbientBindingTests.ReadyStore(store: store, endpoint: host, socket: socket)
    }
}
