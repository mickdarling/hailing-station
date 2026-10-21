import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #737: a reply plays as its audio arrives, with no reserve, so audio that arrives after the queue ran dry is heard
/// as a gap. The meter counts those gaps per playback, and `reply_playback_end` carries them.
@Suite struct PlayoutGapMeterTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    @Test func audioThatArrivesBeforeTheQueueRunsDryIsNoGap() {
        var meter = PlayoutGapMeter()
        meter.scheduled(.milliseconds(500), at: at(0), startsReply: true)
        meter.scheduled(.milliseconds(500), at: at(400), startsReply: false)
        meter.scheduled(.milliseconds(500), at: at(990), startsReply: false)
        #expect(meter.take() == PlayoutGapMeter.Gaps())
    }

    @Test func audioThatArrivesAfterTheQueueRanDryIsAGapOfTheDifference() {
        var meter = PlayoutGapMeter()
        meter.scheduled(.milliseconds(500), at: at(0), startsReply: true)
        meter.scheduled(.milliseconds(500), at: at(800), startsReply: false) // dry at 500: 300 ms gap
        meter.scheduled(.milliseconds(500), at: at(1_400), startsReply: false) // dry at 1300: 100 ms gap
        let gaps = meter.take()
        #expect(gaps.count == 2)
        #expect(gaps.milliseconds == 400)
        #expect(meter.take() == PlayoutGapMeter.Gaps(), "taking starts a new count")
    }

    @Test func aRepliesFirstAudioIsNeverAGapHoweverLongTheQueueWasIdle() {
        var meter = PlayoutGapMeter()
        meter.scheduled(.milliseconds(500), at: at(0), startsReply: true)
        meter.scheduled(.milliseconds(500), at: at(60_000), startsReply: true)
        meter.scheduled(.milliseconds(500), at: at(60_400), startsReply: false)
        #expect(meter.take() == PlayoutGapMeter.Gaps())
    }

    @Test func aGapShorterThanTheThresholdIsSchedulingNoise() {
        var meter = PlayoutGapMeter()
        meter.scheduled(.milliseconds(500), at: at(0), startsReply: true)
        meter.scheduled(.milliseconds(500), at: at(519), startsReply: false)
        meter.scheduled(.milliseconds(500), at: at(1_039), startsReply: false)
        let gaps = meter.take()
        #expect(gaps.count == 1)
        #expect(gaps.milliseconds == 20)
    }

    @Test func timePausedIsNeverAGapAndWhatWasQueuedStillPlaysAfter() {
        var meter = PlayoutGapMeter()
        meter.scheduled(.milliseconds(1_000), at: at(0), startsReply: true)
        meter.paused(at: at(400)) // 600 ms still queued
        meter.scheduled(.milliseconds(500), at: at(5_000), startsReply: false)
        meter.resumed(at: at(9_000)) // 1100 ms queued: dry at 10100
        meter.scheduled(.milliseconds(500), at: at(10_000), startsReply: false)
        #expect(meter.take() == PlayoutGapMeter.Gaps())
        meter.scheduled(.milliseconds(500), at: at(10_900), startsReply: false) // dry at 10600: 300 ms gap
        #expect(meter.take().milliseconds == 300)
    }

    @Test func aClearedQueueStartsAfresh() {
        var meter = PlayoutGapMeter()
        meter.scheduled(.milliseconds(500), at: at(0), startsReply: true)
        meter.cleared()
        meter.scheduled(.milliseconds(500), at: at(3_000), startsReply: false)
        #expect(meter.take() == PlayoutGapMeter.Gaps())
    }

    @MainActor
    @Test func playbackEndCarriesTheGapsHeardSinceItBegan() async throws {
        let suite = "hail-playout-gaps-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let clock = TestInstantClock()
        let log = DeviceDiagnostics(
            defaults: UserDefaults(suiteName: suite) ?? .standard, appInfo: [:], wallNow: { 1_000 },
            clock: { [clock] in clock.now() }
        )
        log.setEnabled(true)
        let player = GapReportingPlayer(gaps: PlayoutGapMeter.Gaps(count: 2, total: .milliseconds(350)))
        let playback = ReplyPlaybackController(player: player)
        log.watch(playback)
        let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
        playback.ingest(HostReplyEvent(endpointID: "main", frame: Frame(
            timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(AudioPayload(
                codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: reply.audioStreamID,
                isFinal: true, bytes: Data([1, 0]), reply: reply)))))
        await settle()
        player.finish()
        await settle()

        var events: [DiagnosticEvent] = []
        while let batch = log.nextBatch() {
            events += batch.events
            clock.advance(by: .seconds(60))
        }
        let end = try #require(events.first { $0.name == .replyPlaybackEnd })
        #expect(end.fields == [.count: .integer(2), .ms: .integer(350)])
    }
}

@MainActor
private final class GapReportingPlayer: ReplyAudioPlaying, PlayoutGapReporting {
    private let gaps: PlayoutGapMeter.Gaps
    private var played: (@MainActor @Sendable () -> Void)?

    init(gaps: PlayoutGapMeter.Gaps) { self.gaps = gaps }

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws { played = onPlayed }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func takePlayoutGaps() -> PlayoutGapMeter.Gaps { gaps }
    func finish() { played?() }
}
