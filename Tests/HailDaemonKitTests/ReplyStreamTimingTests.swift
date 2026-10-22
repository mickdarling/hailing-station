import Testing
@testable import HailDaemonKit

/// #737: a spoken reply's delivery timing. The device plays from the first frame with no reserve, so the lead (audio
/// acknowledged less time since the first acknowledgement) well below zero means the Mac fell behind real time.
@Suite struct ReplyStreamTimingTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    @Test func framesAheadOfPlaybackKeepAPositiveLead() {
        var timing = ReplyStreamTiming(startedAt: at(0))
        timing.sent(audio: .milliseconds(500), at: at(1_200), acknowledgedAfter: .milliseconds(10))
        timing.sent(audio: .milliseconds(750), at: at(1_400), acknowledgedAfter: .milliseconds(12))
        timing.sent(audio: .milliseconds(1_250), at: at(1_900), acknowledgedAfter: .milliseconds(30))
        let summary = timing.summary(at: at(4_000))
        #expect(summary.frames == 3)
        #expect(summary.audio == .milliseconds(2_500))
        #expect(summary.firstAudio == .milliseconds(1_210))
        #expect(summary.minimumLead == .milliseconds(298)) // second frame: 500 ms ahead, acknowledged 202 ms later
        #expect(summary.slowestAcknowledgement == .milliseconds(30))
        #expect(summary.wall == .milliseconds(4_000))
    }

    @Test func aFrameSentAfterTheAudioAheadOfItRanOutGivesANegativeLead() {
        var timing = ReplyStreamTiming(startedAt: at(0))
        timing.sent(audio: .milliseconds(500), at: at(1_000), acknowledgedAfter: .milliseconds(5))
        timing.sent(audio: .milliseconds(1_250), at: at(1_300), acknowledgedAfter: .milliseconds(5))
        // 1750 ms sent, 3000 ms gone since the first frame.
        timing.sent(audio: .milliseconds(1_250), at: at(4_000), acknowledgedAfter: .milliseconds(5))
        #expect(timing.summary(at: at(5_000)).minimumLead == .milliseconds(-1_250))
    }

    @Test func aSlowAcknowledgementOnTheLastFrameShowsAsANegativeLead() {
        var timing = ReplyStreamTiming(startedAt: at(0))
        timing.sent(audio: .milliseconds(500), at: at(1_000), acknowledgedAfter: .milliseconds(5))
        timing.sent(audio: .milliseconds(1_250), at: at(1_100), acknowledgedAfter: .milliseconds(3_000))
        #expect(timing.summary(at: at(5_000)).minimumLead == .milliseconds(-2_595)) // 500 ahead, 3095 later
    }

    @Test func theP95AcknowledgementIgnoresOneSlowOutlierInForty() {
        var timing = ReplyStreamTiming(startedAt: at(0))
        for index in 0..<40 {
            let ack: Duration = index == 7 ? .milliseconds(900) : .milliseconds(10 + index % 5)
            timing.sent(audio: .milliseconds(500), at: at(index * 100), acknowledgedAfter: ack)
        }
        let summary = timing.summary(at: at(5_000))
        #expect(summary.slowestAcknowledgement == .milliseconds(900))
        #expect(summary.acknowledgementP95 == .milliseconds(14))
    }

    @Test func aReplyWithNoAudioSaysSo() {
        let summary = ReplyStreamTiming(startedAt: at(0)).summary(at: at(2_000))
        #expect(summary.line == "reply audio: frames=0 audio_ms=0 first_audio_ms=none min_lead_ms=none "
            + "ack_max_ms=0 ack_p95_ms=0 resends=0 wall_ms=2000")
    }

    @Test func theLogLineCarriesOnlyNumbers() {
        var timing = ReplyStreamTiming(startedAt: at(0))
        timing.sent(audio: .milliseconds(500), at: at(1_000), acknowledgedAfter: .milliseconds(8))
        timing.sent(audio: .milliseconds(750), at: at(1_100), acknowledgedAfter: .milliseconds(9), resends: 2)
        #expect(timing.summary(at: at(3_000)).line == "reply audio: frames=2 audio_ms=1250 first_audio_ms=1008 "
            + "min_lead_ms=399 ack_max_ms=9 ack_p95_ms=9 resends=2 wall_ms=3000")
    }

    @Test func anInstalledHaildLogsAsLiveAndABuildLogsAsDev() {
        let release = "/Users/o/Library/Application Support/HailingStation/releases/830b7a7ac06cc4e4/haild"
        #expect(ReplyTimingLog.category(executablePath: release) == "reply-timing")
        #expect(ReplyTimingLog.category(executablePath: "/opt/homebrew/bin/haild") == "reply-timing")
        #expect(ReplyTimingLog.category(executablePath: nil) == "reply-timing")
        let build = "/Users/o/Developer/hailing-station/.build/arm64-apple-macosx/debug/haild"
        #expect(ReplyTimingLog.category(executablePath: build) == "reply-timing-dev")
        // A path that only names `.build` as part of a word is not a build directory.
        #expect(ReplyTimingLog.category(executablePath: "/Users/o/my.builds/haild") == "reply-timing")
    }
}
