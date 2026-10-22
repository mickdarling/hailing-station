import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #741 round 4: a spoken mute waits for the playing reply and is applied as its final audio's completion arrives,
/// in the same turn the playback end is recorded. The silence after the reply's end must not reach
/// `reply_playback_end` as a gap. The real controller, echo guard and diagnostics, around a player with a real meter.
@MainActor
@Suite struct PlayoutGapControllerTests {
    @Test func aSpokenMuteAtTheReplysEndAddsNoGap() async throws {
        let suite = "hail-playout-mute-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let clock = TestInstantClock()
        let log = DeviceDiagnostics(
            defaults: UserDefaults(suiteName: suite) ?? .standard, appInfo: [:], wallNow: { 1_000 },
            clock: { [clock] in clock.now() }
        )
        log.setEnabled(true)
        let player = MeteredPlayer(clock: clock)
        let playback = ReplyPlaybackController(player: AmbientReplyEchoGuard().guarding(player))
        log.watch(playback)
        let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
        playback.ingest(HostReplyEvent(endpointID: "main", frame: Frame(
            timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(AudioPayload(
                codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: reply.audioStreamID,
                isFinal: true, bytes: Data(count: 2_400), reply: reply)))))
        await settle()
        playback.setReplyMute(true) // waits for the playing reply
        clock.advance(by: .milliseconds(200)) // its 50 ms of audio, then output latency
        player.finish()
        await settle()

        var events: [DiagnosticEvent] = []
        while let batch = log.nextBatch() {
            events += batch.events
            clock.advance(by: .seconds(60))
        }
        let end = try #require(events.first { $0.name == .replyPlaybackEnd })
        #expect(end.fields == [.count: .integer(0), .ms: .integer(0)])
    }
}

@MainActor
private final class MeteredPlayer: ReplyAudioPlaying, PlayoutGapReporting {
    private let clock: TestInstantClock
    private var meter = PlayoutGapMeter()
    private var played: (@MainActor @Sendable () -> Void)?

    init(clock: TestInstantClock) { self.clock = clock }

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        let audio = Duration.seconds(Double(payload.bytes.count / 2) / Double(payload.sampleRate))
        meter.scheduled(audio, at: clock.now(), startsReply: payload.sequence == 0, endsReply: payload.isFinal)
        played = onPlayed
    }
    func cancel() { meter.cleared() }
    func pause() { meter.paused(at: clock.now()) }
    func resume() { meter.resumed(at: clock.now()) }
    func setMuted(_ muted: Bool) { meter.muteChanged(muted, at: clock.now()) }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func takePlayoutGaps() -> PlayoutGapMeter.Gaps { meter.take() }
    func finish() { played?() }
}
