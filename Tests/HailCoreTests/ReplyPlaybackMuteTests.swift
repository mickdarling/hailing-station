import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// The device side of `set_reply_mute` (#404): advertised in the hello, handed to the reply player, and carried out
/// as the mute control: a voice mute lets the reply now playing (the host's spoken "Muted.") finish first.
@MainActor
@Suite struct ReplyPlaybackMuteTests {
    @Test func theHelloAdvertisesReplyMuteAndTheControlReachesTheReplyPlayer() async throws {
        let endpoint = try endpoint()
        let socket = ScriptedSocket()
        let connector = ScriptedConnector()
        let replies = MuteEvents()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(
            endpoint: endpoint, connector: connector, replyObserver: { await replies.append($0) }
        )
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        guard case .control(.hello(let info)) = try await socket.sentFrames().first?.payload else {
            Issue.record("expected the device hello first")
            return
        }
        #expect(info.capabilities.contains(ReplyMute.capability))
        try await socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current], capabilities: [],
                                               deviceName: "Mac")))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        let mute = Frame(timestamp: 1, source: "host", payload: .control(.setReplyMute(muted: true)))
        try await socket.push(FrameCoding.encode(mute))
        try await waitUntil { await replies.values.count == 1 }
        #expect(await replies.values == [HostReplyEvent(endpointID: endpoint.id, frame: mute)])
        await connection.disconnect()
    }

    @Test func aMuteWithNothingPlayingAppliesAtOnce() {
        let player = MutePlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(control(.setReplyMute(muted: true)))
        #expect(controller.isMuted && player.muted)
        #expect(controller.status == "Muted")
    }

    @Test func aMuteLetsTheConfirmationFinishThenLaterRepliesAreSilent() {
        let player = MutePlayer()
        let controller = ReplyPlaybackController(player: player)
        let confirmation = idleReply(), later = idleReply()
        controller.ingest(idleAudio(confirmation, sequence: 0, final: true, byte: 10)) // "Muted."
        controller.ingest(control(.setReplyMute(muted: true)))
        #expect(!controller.isMuted && !player.muted) // the confirmation is heard
        controller.ingest(idleAudio(later, sequence: 0, final: true, byte: 20))
        player.completeReply()
        #expect(controller.isMuted && player.muted) // before the later reply starts
        #expect(player.scheduled.last?.bytes.first == 20)
        #expect(player.mutedWhenScheduled.last == true)
    }

    @Test func anUnmuteIsImmediateAndCancelsAWaitingMute() {
        let player = MutePlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 10))
        controller.ingest(control(.setReplyMute(muted: true)))
        controller.ingest(control(.setReplyMute(muted: false)))
        player.completeReply()
        #expect(!controller.isMuted && !player.muted)
        controller.ingest(control(.setReplyMute(muted: true)))
        controller.ingest(control(.setReplyMute(muted: false)))
        #expect(!controller.isMuted && !player.muted)
    }

    @Test func theMuteControlReplacesAWaitingVoiceMute() {
        let player = MutePlayer()
        let controller = ReplyPlaybackController(player: player)
        controller.ingest(idleAudio(idleReply(), sequence: 0, final: true, byte: 10))
        controller.ingest(control(.setReplyMute(muted: true)))
        controller.toggleMute() // the user mutes now
        controller.toggleMute() // and unmutes
        player.completeReply()
        #expect(!controller.isMuted) // the earlier voice mute does not come back
    }

    @Test func aRepeatedControlFrameIsCarriedOutOnce() {
        let player = MutePlayer()
        let controller = ReplyPlaybackController(player: player)
        let mute = control(.setReplyMute(muted: true))
        controller.ingest(mute)
        controller.toggleMute() // the user unmutes
        controller.ingest(mute) // the same frame again
        #expect(!controller.isMuted)
    }
}

private func control(_ payload: ControlPayload) -> HostReplyEvent {
    HostReplyEvent(endpointID: "main", frame: Frame(timestamp: 1, source: "host", payload: .control(payload)))
}

private actor MuteEvents {
    private(set) var values: [HostReplyEvent] = []
    func append(_ event: HostReplyEvent) { values.append(event) }
}

private final class MutePlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var mutedWhenScheduled: [Bool] = []
    var muted = false
    private var completions: [@MainActor @Sendable () -> Void] = []

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        mutedWhenScheduled.append(muted)
        if let onPlayed { completions.append(onPlayed) }
    }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) { self.muted = muted }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func completeReply() { completions.removeFirst()() }
}
