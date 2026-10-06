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
        #expect(spoken.isEcho("the first sentence reaches your phone quickly"))
        clock.advance(by: .milliseconds(200))
        #expect(!spoken.isEcho("the first sentence reaches your phone quickly"))
    }

    @Test func mickTalkingOverTheReplyIsNotEcho() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        spoken.observe(text())
        spoken.observe(audio(seconds: 6, sequence: 0))
        #expect(!spoken.isEcho("hold on, what is the status of the build"))
        // Barely overlapping: one shared pair out of five is far under the threshold.
        #expect(!spoken.isEcho("no the relay is broken again today"))
        // Follow-ups that reuse the reply's phrases (PR #275 review) stay below the threshold.
        #expect(!spoken.isEcho("wait, the streaming relay is up?"))
        #expect(!spoken.isEcho("so the first sentence reaches my phone how quickly"))
    }

    @Test func shortCommandsAreNeverEchoEvenWhenTheReplyContainsThem() {
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        spoken.observe(text())
        spoken.observe(audio(seconds: 6, sequence: 0))
        #expect(!spoken.isEcho("sir"))
        #expect(!spoken.isEcho("status update"))
        #expect(!spoken.isEcho("the relay is up?"))
    }

    @Test func aReplyQueuedBehindAnotherIsEchoUntilItsOwnLaterPlaybackEnds() {
        // Codex P1 on #275: the phone plays replies in turn, so the second starts when the first ends.
        let clock = Clock()
        let spoken = RecentSpokenReplies(now: { clock.now })
        let first = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "tmux:test", audioStreamID: UUID(),
                                    requestID: UUID())
        spoken.observe(Frame(timestamp: 0, target: "tmux:test", source: "mac-test", payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: first.audioStreamID,
            isFinal: false, bytes: Data(count: 20 * 48_000), reply: first))))
        spoken.observe(text())
        spoken.observe(audio(seconds: 6, sequence: 0)) // Plays from 20 s to 26 s, not from 0 s.
        clock.advance(by: .seconds(26) + RecentSpokenReplies.hold - .milliseconds(100))
        #expect(spoken.isEcho("the first sentence reaches your phone quickly"))
    }

    @Test func aTextOnlyReplyIsNeverEcho() {
        // Codex P2 on #275: `haild reply --text` is shown, not spoken.
        let spoken = RecentSpokenReplies()
        spoken.observe(text())
        #expect(!spoken.isEcho("the first sentence reaches your phone quickly"))
    }

    @Test func withoutARecentReplyNothingIsEcho() {
        let spoken = RecentSpokenReplies()
        #expect(!spoken.isEcho("the streaming relay is up and the first sentence"))
    }
}
#endif

#if os(macOS)
/// Through the consumer (PR #275 review): the filter sees the heard turn, not the built prompt, whose JSON
/// envelope and reply block would bury the echo's word pairs.
extension RightyoInputConsumerTests {
    func echoTurn(_ text: String) -> [String: Any] {
        var heard = turn()
        heard["text"] = text
        return heard
    }

    @Test func heardEchoOfTheSpokenReplyIsDroppedBeforeDispatch() async throws {
        let spoken = RecentSpokenReplies()
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: "tmux:demo", audioStreamID: nil,
                                    requestID: UUID())
        spoken.observe(Frame(timestamp: 0, target: "tmux:demo", source: "mac-test", payload: .text(TextPayload(
            text: "The streaming relay is up, and the first sentence reaches your phone quickly.", reply: reply))))
        spoken.observe(Frame(timestamp: 0, target: "tmux:demo", source: "mac-test", payload: .audio(AudioPayload(
            codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: UUID(), isFinal: false,
            bytes: Data(count: 48_000), reply: reply))))
        let dispatcher = RecordingDispatcher()
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "pinned", session: session,
                                                allowSynthetic: true, dispatcher: dispatcher,
                                                echoFilter: { spoken.isEcho($0) })
        _ = try await consumer.consume(start())
        let echo = try await preparedRequest(consumer, customTurn: echoTurn("the first sentence reaches your phone"))
        #expect(try await !consumer.consume(echo))
        #expect(await dispatcher.calls.isEmpty)
        #expect(await consumer.echoDropped == 1)
    }

    @Test func micksOwnRequestPassesTheEchoFilter() async throws {
        let dispatcher = RecordingDispatcher()
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "pinned", session: session,
                                                allowSynthetic: true, dispatcher: dispatcher,
                                                echoFilter: { _ in false })
        _ = try await consumer.consume(start())
        #expect(try await consumer.consume(preparedRequest(consumer)))
        #expect(await dispatcher.calls.count == 1)
        #expect(await consumer.echoDropped == 0)
    }
}
#endif
