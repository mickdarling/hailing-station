#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Synthetic clock-only regressions for late confirmed audio (#904, #269).
@Suite(.frozenGuardBudget) struct RecentSpokenRepliesLateAudioTests {
    typealias Clock = RecentSpokenRepliesTests.Clock
    static let words = "The synthetic reply is ready for the next testing step"

    func reply() -> ReplyDescriptor {
        ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "tmux:test", audioStreamID: UUID())
    }

    func text(_ reply: ReplyDescriptor) -> Frame {
        Frame(timestamp: 0, target: reply.targetID, source: reply.hostID,
              payload: .text(TextPayload(text: Self.words, reply: reply)))
    }

    func audio(_ reply: ReplyDescriptor, seconds: Int = 1) -> Frame {
        Frame(timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: reply.audioStreamID,
            isFinal: false, bytes: Data(count: seconds * 48_000), reply: reply)))
    }

    @Test func prunedWordsReturnWithLateAudio() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let original = reply()
        spoken.observe(text(original))
        spoken.observe(audio(original))
        clock.advance(by: .seconds(16))
        spoken.observe(text(reply())) // Another peer's acknowledgement prunes the original.
        #expect(!spoken.isEcho(Self.words)) // Remembered words alone do not protect anything.
        spoken.observe(audio(original))
        #expect(spoken.isEcho(Self.words))
    }

    @Test func delayedSegmentGetsItsFullPlaybackAndHold() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let original = reply()
        spoken.observe(text(original))
        spoken.observe(audio(original))
        clock.advance(by: .seconds(16))
        spoken.observe(audio(original))
        clock.advance(by: RecentSpokenReplies.hold + .milliseconds(900))
        #expect(spoken.isEcho(Self.words))
        clock.advance(by: .milliseconds(100))
        #expect(!spoken.isEcho(Self.words))
    }

    @Test(arguments: [false, true]) func rememberedWordsExpireAtTheirBound(expired: Bool) {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let original = reply()
        spoken.observe(text(original))
        spoken.observe(audio(original))
        clock.advance(by: .seconds(6))
        spoken.observe(text(reply())) // Retire the original at this instant.
        #expect(RecentSpokenReplies.wordRetention == .seconds(60))
        clock.advance(by: RecentSpokenReplies.wordRetention - (expired ? .zero : .milliseconds(1)))
        #expect(!spoken.isEcho(Self.words))
        spoken.observe(audio(original))
        #expect(spoken.isEcho(Self.words) == !expired)
    }

    @Test func evictedWordsReturnWithLateAudio() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let original = reply()
        spoken.observe(text(original))
        spoken.observe(audio(original))
        for _ in 0..<RecentSpokenReplies.maxReplies {
            clock.advance(by: .milliseconds(1))
            spoken.observe(text(reply()))
        }
        #expect(!spoken.isEcho(Self.words)) // The live entry was evicted, while its audio would still play.
        spoken.observe(audio(original))
        #expect(spoken.isEcho(Self.words))
    }

    @Test(arguments: 0...RecentSpokenReplies.maxReplies) func rememberedWordsAreCapped(index: Int) {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let originals = (0...RecentSpokenReplies.maxReplies).map { _ in reply() }
        for original in originals {
            spoken.observe(text(original))
            clock.advance(by: .milliseconds(1))
        }
        // The first entry was evicted; pruning the remaining eight fills the retired-words cache to nine.
        clock.advance(by: .seconds(5))
        spoken.observe(text(reply()))
        #expect(!spoken.isEcho(Self.words))
        spoken.observe(audio(originals[index]))
        #expect(spoken.isEcho(Self.words) == (index > 0)) // All eight newest IDs survive, only the oldest is lost.
    }

    @Test func delayedSegmentQueuesBehindOtherPlayback() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let original = reply()
        spoken.observe(text(original))
        spoken.observe(audio(original))
        clock.advance(by: .seconds(2))
        spoken.observe(audio(reply(), seconds: 10)) // Other reply plays from 2 s through 12 s.
        spoken.observe(audio(original)) // Delayed segment plays from 12 s through 13 s.
        clock.advance(by: .seconds(11) + RecentSpokenReplies.hold - .milliseconds(1))
        #expect(spoken.isEcho(Self.words))
        clock.advance(by: .milliseconds(1))
        #expect(!spoken.isEcho(Self.words))
    }

    @Test func uninterruptedSegmentsStillAccumulate() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let original = reply()
        spoken.observe(text(original))
        spoken.observe(audio(original, seconds: 2))
        clock.advance(by: .seconds(1))
        spoken.observe(audio(original)) // Playback ends at 3 s, without a restart.
        clock.advance(by: .seconds(2) + RecentSpokenReplies.hold - .milliseconds(1))
        #expect(spoken.isEcho(Self.words))
        clock.advance(by: .milliseconds(1))
        #expect(!spoken.isEcho(Self.words))
    }
}
#endif
