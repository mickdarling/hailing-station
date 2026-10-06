#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Own-voice rejection (#269 stage 1): an ambient request that repeats a reply still playing, or just finished,
/// is the assistant hearing itself and is dropped; Mick's own words, and short commands, are not.
@Suite struct RecentSpokenRepliesTests {
    final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(by duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
    }

    static let replyText =
        "Status update, sir. The streaming relay is up, and the first sentence reaches your phone quickly."
    let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "tmux:test", audioStreamID: UUID(),
                                requestID: UUID())

    func text() -> Frame {
        Frame(timestamp: 0, target: "tmux:test", source: "mac-test",
              payload: .text(TextPayload(text: Self.replyText, reply: reply)))
    }

    /// `seconds` of 24 kHz mono PCM16 for this reply.
    func audio(seconds: Double, sequence: Int) -> Frame {
        Frame(timestamp: 0, target: "tmux:test", source: "mac-test", payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence, streamID: reply.audioStreamID,
            isFinal: false, bytes: Data(count: Int(seconds * 48_000)), reply: reply)))
    }

    @Test func theReplyHeardBackWhilePlayingIsEcho() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        spoken.observe(text())
        spoken.observe(audio(seconds: 6, sequence: 0))
        clock.advance(by: .seconds(3))
        #expect(spoken.isEcho("the streaming relay is up and the first sentence"))
        #expect(spoken.isEcho("Status update, sir. The streaming relay is up"))
    }

    @Test func echoLastsUntilTheHoldAfterEstimatedPlaybackEnds() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        spoken.observe(text())
        spoken.observe(audio(seconds: 6, sequence: 0))
        clock.advance(by: .seconds(6) + RecentSpokenReplies.hold - .milliseconds(100))
        #expect(spoken.isEcho("reaches your phone quickly"))
        clock.advance(by: .milliseconds(200))
        #expect(!spoken.isEcho("reaches your phone quickly"))
    }

    @Test func mickTalkingOverTheReplyIsNotEcho() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        spoken.observe(text())
        spoken.observe(audio(seconds: 6, sequence: 0))
        #expect(!spoken.isEcho("hold on, what is the status of the build"))
        // Barely overlapping: one shared pair out of five is far under the threshold.
        #expect(!spoken.isEcho("no the relay is broken again today"))
    }

    @Test func shortCommandsAreNeverEchoEvenWhenTheReplyContainsThem() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        spoken.observe(text())
        #expect(!spoken.isEcho("sir"))
        #expect(!spoken.isEcho("status update"))
    }

    @Test func withoutARecentReplyNothingIsEcho() {
        let spoken = RecentSpokenReplies()
        #expect(!spoken.isEcho("the streaming relay is up and the first sentence"))
    }
}
#endif
