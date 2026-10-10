import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// A reply player that models an `AVAudioPlayerNode` on a capture engine: a scheduled reply stays "in flight"
/// until the node is stopped, which fires its completion, and a stopped node plays again on the next schedule.
@MainActor
private final class RoutedFakePlayer: ReplyAudioPlaying, CaptureRoutedReplies {
    private(set) var engine: AVAudioEngine?
    private(set) var isPlaying = false
    private var pending: [@MainActor @Sendable () -> Void] = []
    private(set) var restartsSeen = 0

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        if let onPlayed { pending.append(onPlayed) }
        if !isPlaying { isPlaying = true }
    }
    func cancel() { stopNode() }
    func pause() {}
    func resume() {}
    func setMuted(_: Bool) {}
    func replaceQueue(with _: [AudioPayload], onPlayed _: (@MainActor @Sendable () -> Void)?) {}

    func route(through capture: AVAudioEngine?) { engine = capture }
    var isRoutedThroughCapture: Bool { engine != nil }
    func isOnAnotherCapture(than capture: AVAudioEngine) -> Bool { engine != nil && engine !== capture }
    func captureEngineRestarted(_ capture: AVAudioEngine) {
        guard engine === capture else { return }
        restartsSeen += 1
        stopNode()
    }

    private func stopNode() {
        isPlaying = false
        let completions = pending
        pending = []
        for completion in completions { completion() }
    }
}

private func replyAudio() -> AudioPayload {
    let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
    return AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: reply.audioStreamID,
        isFinal: true, bytes: Data([1, 0]), reply: reply
    )
}

/// #443 review round 1: a restart also drops a reply the stall froze on the same engine, so the playback queue and
/// the echo guard move on; one late wake after a suspension is not a stall.
@MainActor
@Suite struct AudioEngineCaptureStallRecoveryTests {
    let center = NotificationCenter()
    let fake = CountingEngineOperations()
    let sleeper = SteppedSleeper()
    static let policy = AVAudioEngineCapture.StallPolicy(limit: .seconds(5), check: .seconds(1), maxRestarts: 2)

    func engineCapture(_ engine: AVAudioEngine = AVAudioEngine()) -> AVAudioEngineCapture {
        let sleeper = sleeper
        return AVAudioEngineCapture(
            engine: engine, notificationCenter: center, operations: fake.operations,
            stallPolicy: Self.policy, now: { sleeper.clock.now() }, sleep: { try await sleeper.sleep($0) }
        )
    }

    /// Advances `duration` and waits until the watchdog has slept again.
    func step(_ duration: Duration = .seconds(1)) async throws {
        try await waitUntil { [sleeper] in sleeper.isWaiting }
        sleeper.tick(duration)
        try await waitUntil { [sleeper] in sleeper.isWaiting }
    }

    @Test func aReplyFrozenByTheStallCompletesAndTheNextReplyPlays() async throws {
        let echoGuard = AmbientReplyEchoGuard()
        let player = RoutedFakePlayer()
        _ = echoGuard.guarding(player)
        let capture = try echoGuard.ambientCapture(mode: .plain) { engineCapture($0) }
        let stream = try capture.start()
        #expect(player.engine != nil, "replies play through the capture engine")

        var frozenReplyDone = false
        player.schedule(replyAudio()) { frozenReplyDone = true }
        for _ in 0..<5 { try await step() }

        #expect(fake.starts == 2, "the stalled engine restarted")
        #expect(player.restartsSeen == 1)
        #expect(frozenReplyDone, "the frozen reply's completion fired, so the queue and masking move on")
        #expect(!player.isPlaying)
        player.schedule(replyAudio(), onPlayed: nil)
        #expect(player.isPlaying, "the next reply plays on the restarted engine")
        capture.stop()
        withExtendedLifetime((stream, player)) {}
    }

    @Test func theHookRunsOncePerSuccessfulRestart() async throws {
        let capture = engineCapture()
        var restarted = 0
        capture.onEngineRestarted = { restarted += 1 }
        let stream = try capture.start()
        for _ in 0..<5 { try await step() }
        #expect(restarted == 1)
        capture.stop()
        withExtendedLifetime(stream) {}
    }

    @Test func oneLateWakeAfterASuspensionIsNotAStall() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled, AVAudioEngineCapture.endedBySystem])
        let capture = engineCapture()
        let stream = try capture.start()
        // Audio flows up to the suspension: the last check before it saw a new buffer.
        try await waitUntil { [sleeper] in sleeper.isWaiting }
        fake.feed(try sineBuffer())
        try await step()
        try await step(.seconds(60))
        #expect(notes.named(AVAudioEngineCapture.stalled).isEmpty, "a single 60 s check is a suspension, not a stall")
        fake.feed(try sineBuffer())
        try await step()
        #expect(notes.named(AVAudioEngineCapture.stalled).isEmpty)
        #expect(fake.starts == 1)
        capture.stop()
        withExtendedLifetime(stream) {}
    }

    @Test func aMicStillSilentOnTheNextCheckAfterASuspensionIsAStall() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled])
        let capture = engineCapture()
        let stream = try capture.start()
        try await step(.seconds(60))
        #expect(notes.named(AVAudioEngineCapture.stalled).isEmpty)
        try await step()
        #expect(notes.named(AVAudioEngineCapture.stalled).count == 1)
        #expect(fake.starts == 2)
        capture.stop()
        withExtendedLifetime(stream) {}
    }

    @Test func theAmbientPolicyRestartsTwiceThenEnds() {
        #expect(AVAudioEngineCapture.StallPolicy.ambient.maxRestarts == 2)
        #expect(AVAudioEngineCapture.StallPolicy.ambient.limit == .seconds(5))
    }
}
