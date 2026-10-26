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

    func audio(_ reply: ReplyDescriptor, seconds: Int = 1, sequence: Int = 0, isFinal: Bool = false) -> Frame {
        Frame(timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence, streamID: reply.audioStreamID,
            isFinal: isFinal, bytes: Data(count: seconds * 48_000), reply: reply)))
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
        spoken.observe(text(original))
        #expect(!spoken.isEcho(Self.words)) // Restored text cannot revive a playback span that has ended.
        spoken.observe(audio(reply(), seconds: 20, isFinal: true)) // Later stream cannot delay the restored head.
        spoken.observe(audio(original))
        #expect(spoken.isEcho(Self.words))
        clock.advance(by: .seconds(1) + RecentSpokenReplies.hold)
        #expect(!spoken.isEcho(Self.words))
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
        spoken.observe(audio(original, seconds: 10))
        for _ in 0..<RecentSpokenReplies.maxReplies {
            clock.advance(by: .milliseconds(1))
            spoken.observe(text(reply()))
        }
        #expect(!spoken.isEcho(Self.words)) // The live entry was evicted, while its audio would still play.
        spoken.observe(audio(original, sequence: 1, isFinal: true)) // Appends to buffered audio: plays [10,11].
        // Check every millisecond through buffered playback, the final [10,11] frame, hold, and past expiry.
        for elapsedMs in 9...15_001 {
            clock.advance(by: .milliseconds(1))
            #expect(spoken.isEcho(Self.words) == (elapsedMs < 15_000))
        }
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

    @Test func delayedSegmentKeepsItsPlaceAheadOfLaterStreams() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let original = reply()
        spoken.observe(text(original))
        spoken.observe(audio(original))
        clock.advance(by: .seconds(2))
        spoken.observe(audio(reply(), seconds: 10, isFinal: true)) // Waits for the original's final frame.
        spoken.observe(audio(original, sequence: 1, isFinal: true)) // Original still owns the head: plays [2,3].
        clock.advance(by: .seconds(1) + RecentSpokenReplies.hold - .milliseconds(1))
        #expect(spoken.isEcho(Self.words))
        clock.advance(by: .milliseconds(1))
        #expect(!spoken.isEcho(Self.words))
    }

    @Test func terminalFIFOKeepsOwnerRepetitionOutOfALaterStreamsWindow() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let first = reply(), second = reply()
        spoken.observe(text(first))
        spoken.observe(audio(first)) // Non-final A plays [0,1] and holds the terminal FIFO head.
        clock.advance(by: .milliseconds(500))
        spoken.observe(audio(second, seconds: 20, isFinal: true)) // B waits for A, even when A runs dry.
        clock.advance(by: .milliseconds(1_500))
        spoken.observe(audio(first, sequence: 1, isFinal: true)) // A plays [2,3], then B plays [3,23].
        clock.advance(by: .milliseconds(999))
        #expect(spoken.isEcho(Self.words)) // During A's real playback.
        clock.advance(by: RecentSpokenReplies.hold)
        #expect(spoken.isEcho(Self.words)) // Through A's real playback plus hold, just before t=7.
        clock.advance(by: .milliseconds(1))
        #expect(!spoken.isEcho(Self.words))
        clock.advance(by: .seconds(1))
        #expect(!spoken.isEcho(Self.words)) // A genuine owner repetition at t=8 must pass.
    }

    @Test func delayedSegmentStillQueuesBehindEarlierStreams() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let first = reply(), second = reply()
        spoken.observe(audio(first))
        spoken.observe(text(second))
        spoken.observe(audio(second))
        clock.advance(by: .seconds(2))
        spoken.observe(audio(first, seconds: 20, sequence: 1, isFinal: true)) // Earlier A ends at t=22.
        clock.advance(by: .seconds(1))
        spoken.observe(audio(second, sequence: 1, isFinal: true)) // B's expired estimate re-anchors behind A.
        clock.advance(by: .seconds(24) - .milliseconds(1))
        #expect(spoken.isEcho(Self.words)) // Protect B through the re-anchored estimate plus hold.
        // P2 remains: B's previously queued audio also waits for A, but its existing window was not shifted.
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
