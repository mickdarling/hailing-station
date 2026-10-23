import Testing
@testable import HailCore

/// #825: a reply plays the moment its first audio arrives; a stall holds until enough audio is queued ahead, rather
/// than playing each late frame as it lands; the target grows with stalls and shrinks after clean replies.
@Suite struct ReplyPlayoutBufferTests {
    private let half = Duration.milliseconds(500)

    @Test func aReplyStartsAtOnceWithNoAddedDelay() {
        var buffer = ReplyPlayoutBuffer()
        let plays = buffer.queued([half], startsReply: true, endsReply: false)
        #expect(plays)
        #expect(!buffer.isCatchingUp)
        #expect(buffer.policy.target == .zero)
    }

    @Test func aReplyThatPlaysThroughNeverHolds() {
        var buffer = ReplyPlayoutBuffer()
        _ = buffer.queued([half], startsReply: true, endsReply: false)
        _ = buffer.queued([half, half], startsReply: false, endsReply: false)
        var stalls = [buffer.played(half)]
        _ = buffer.queued([half], startsReply: false, endsReply: true)
        for _ in 0..<3 { stalls.append(buffer.played(half)) }
        #expect(stalls.allSatisfy { !$0 })
        #expect(!buffer.isCatchingUp)
        #expect(buffer.policy.target == .zero)
    }

    @Test func runningDryMidReplyHoldsUntilTheTargetIsQueued() {
        var buffer = ReplyPlayoutBuffer()
        _ = buffer.queued([half], startsReply: true, endsReply: false)
        let stalled = buffer.played(half)
        #expect(stalled, "the queue ran dry before the final audio: a stall")
        #expect(buffer.isCatchingUp)
        #expect(buffer.policy.target == .milliseconds(500))
        // A late frame shorter than the target is held, not played as it lands.
        let playsEarly = buffer.queued([.milliseconds(250)], startsReply: false, endsReply: false)
        #expect(!playsEarly)
        #expect(buffer.isCatchingUp)
        let playsOnTarget = buffer.queued([.milliseconds(250)], startsReply: false, endsReply: false)
        #expect(playsOnTarget)
        #expect(!buffer.isCatchingUp)
    }

    @Test func theFinalAudioArrivingAlwaysPlaysOn() {
        var buffer = ReplyPlayoutBuffer()
        _ = buffer.queued([half], startsReply: true, endsReply: false)
        _ = buffer.played(half)
        let plays = buffer.queued([.milliseconds(100)], startsReply: false, endsReply: true)
        #expect(plays)
        #expect(!buffer.isCatchingUp)
    }

    @Test func eachStallRaisesTheTargetUpToTwoSeconds() {
        var buffer = ReplyPlayoutBuffer()
        _ = buffer.queued([half], startsReply: true, endsReply: false)
        var frame = half
        for expected in [Duration.milliseconds(500), .seconds(1), .seconds(2), .seconds(2)] {
            let stalled = buffer.played(frame)
            #expect(stalled)
            #expect(buffer.policy.target == expected)
            frame = .seconds(3)
            let plays = buffer.queued([frame], startsReply: false, endsReply: false)
            #expect(plays, "three seconds covers any target")
        }
    }

    @Test func aDryQueueWhileAlreadyHoldingIsNotASecondStall() {
        var buffer = ReplyPlayoutBuffer()
        _ = buffer.queued([half], startsReply: true, endsReply: false)
        _ = buffer.played(half)
        let again = buffer.played(half)
        #expect(!again, "nothing was queued: no new stall")
        #expect(buffer.policy.target == .milliseconds(500))
    }

    @Test func cleanRepliesLowerTheTargetAStepAtATime() {
        var buffer = ReplyPlayoutBuffer()
        stall(&buffer)
        stall(&buffer)
        #expect(buffer.policy.target == .seconds(1))
        for _ in 0..<(ReplyPlayoutPolicy.cleanRepliesPerStep - 1) { playCleanReply(&buffer) }
        #expect(buffer.policy.target == .seconds(1), "not yet enough clean replies")
        playCleanReply(&buffer)
        #expect(buffer.policy.target == .milliseconds(500))
        for _ in 0..<ReplyPlayoutPolicy.cleanRepliesPerStep { playCleanReply(&buffer) }
        #expect(buffer.policy.target == .zero)
    }

    @Test func aReplyThatStalledDoesNotCountAsClean() {
        var buffer = ReplyPlayoutBuffer()
        stall(&buffer)
        for _ in 0..<5 { stall(&buffer, newReply: true) }
        #expect(buffer.policy.target == .seconds(2))
    }

    @Test func aNewReplyNeverWaitsEvenAfterStalls() {
        var buffer = ReplyPlayoutBuffer()
        stall(&buffer)
        stall(&buffer)
        #expect(buffer.isCatchingUp)
        let plays = buffer.queued([.milliseconds(100)], startsReply: true, endsReply: false)
        #expect(plays)
        #expect(!buffer.isCatchingUp)
    }

    @Test func clearingDropsTheHoldButKeepsWhatTheLinkTaughtIt() {
        var buffer = ReplyPlayoutBuffer()
        stall(&buffer)
        buffer.cleared()
        #expect(!buffer.isCatchingUp)
        #expect(buffer.ahead == .zero)
        #expect(buffer.policy.target == .milliseconds(500))
        let late = buffer.played(half)
        #expect(!late, "a completion after a clear is not a stall")
    }

    /// Queues one half-second frame and plays it with nothing behind it: one stall. A new reply then ends cleanly.
    private func stall(_ buffer: inout ReplyPlayoutBuffer, newReply: Bool = false) {
        _ = buffer.queued([half], startsReply: newReply, endsReply: false)
        _ = buffer.played(half)
        guard newReply else { return }
        _ = buffer.queued([half], startsReply: false, endsReply: true)
        _ = buffer.played(half)
    }

    private func playCleanReply(_ buffer: inout ReplyPlayoutBuffer) {
        _ = buffer.queued([half], startsReply: true, endsReply: false)
        _ = buffer.queued([half], startsReply: false, endsReply: true)
        _ = buffer.played(half)
        _ = buffer.played(half)
    }
}
