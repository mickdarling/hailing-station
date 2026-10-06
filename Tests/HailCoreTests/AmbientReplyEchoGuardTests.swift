import AVFAudio
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailCore

/// A hand-advanced clock so the echo guard's tail is tested without sleeping.
final class EchoGuardClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
}

/// The silence-while-speaking debounce (#227): reply audio and a short tail never reach the host as microphone audio.
@MainActor
@Suite struct AmbientReplyEchoGuardTests {
    @Test func masksWhileAReplyIsAudibleAndForTheTailAfterIt() {
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { clock.now })
        #expect(!echoGuard.isMasking)

        echoGuard.setReplyAudible(true)
        #expect(echoGuard.isMasking)
        clock.advance(by: .seconds(5))
        #expect(echoGuard.isMasking)

        echoGuard.setReplyAudible(false)
        clock.advance(by: .milliseconds(399))
        #expect(echoGuard.isMasking)
        clock.advance(by: .milliseconds(1))
        #expect(!echoGuard.isMasking)
    }

    @Test func echoCancelledRepliesLeaveTheMicrophoneOpenUnlessTheABSwitchMasks() {
        // #269: replies routed through the capture's echo canceller are not masked; the A/B switch restores #227.
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { clock.now })
        echoGuard.setRoutedThroughCapture(true)
        echoGuard.setReplyAudible(true)
        #expect(echoGuard.isEchoCancelling)
        #expect(!echoGuard.isMasking)
        echoGuard.masksDuringReplies = true
        #expect(echoGuard.isMasking)
        echoGuard.masksDuringReplies = false
        echoGuard.setRoutedThroughCapture(false)
        #expect(echoGuard.isMasking) // Not routed: masking remains the fallback.
    }

    @Test func aRepeatedQuietReportDoesNotRestartTheTail() {
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { clock.now })
        echoGuard.setReplyAudible(true)
        echoGuard.setReplyAudible(false)
        clock.advance(by: .milliseconds(300))
        echoGuard.setReplyAudible(false)
        clock.advance(by: .milliseconds(100))
        #expect(!echoGuard.isMasking)
    }

    @Test func silencesBuffersOnlyWhileMasking() throws {
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(now: { clock.now })
        let open = try sineBuffer()
        #expect(!echoGuard.silenceIfMasking(open))
        #expect(try peak(open) > 0.4)

        echoGuard.setReplyAudible(true)
        let masked = try sineBuffer()
        #expect(echoGuard.silenceIfMasking(masked))
        #expect(try peak(masked) == 0)
        #expect(masked.frameLength == 4_800)
    }

    @Test func streamerSendsContinuousSilenceWhileSpeakingThenMicrophoneAudio() async throws {
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { clock.now })
        let capture = FakeAudioCapture()
        let sent = SentAudio()
        let streamer = AmbientAudioStreamer(capture: echoGuard.masking(capture), send: { await sent.send($0) })
        echoGuard.setReplyAudible(true)

        try streamer.start()
        for block in 0..<4 { try capture.yield(sineBuffer(offset: block * 4_800)) }
        // Two sent plus one held is 300 ms of output, which converter latency only completes with the fourth
        // buffer, so all four passed the guard while it masked.
        try await waitUntil { await sent.payloads.count >= 2 }
        echoGuard.setReplyAudible(false)
        clock.advance(by: .milliseconds(400))
        for block in 4..<7 { try capture.yield(sineBuffer(offset: block * 4_800)) }
        await streamer.stop()

        let payloads = await sent.payloads
        #expect(payloads.map(\.sequence) == Array(0..<payloads.count))
        #expect(payloads.dropLast().allSatisfy { $0.bytes.count == AmbientAudioFormat.chunkBytes })
        #expect(payloads.prefix(2).allSatisfy { $0.bytes.allSatisfy { $0 == 0 } })
        #expect(payloads.dropFirst(4).contains { $0.bytes.contains { $0 != 0 } })
    }

    @Test func unmutingWithNothingPlayingLeavesTheMicrophoneOpen() async {
        let harness = AmbientDuplexPlaybackTests.Harness()
        harness.playback.toggleMute()
        harness.playback.toggleMute()
        #expect(harness.player.calls == [.init(name: "unmute", masking: false)])
        await settle()
        #expect(!harness.echoGuard.isMasking)
    }

    @Test func unmutingAPausedReplyLeavesTheMicrophoneOpen() async {
        let harness = AmbientDuplexPlaybackTests.Harness()
        harness.playback.ingest(duplexEvent())
        harness.playback.togglePause()
        harness.playback.toggleMute()
        await harness.quiet()
        harness.playback.toggleMute()
        #expect(harness.player.calls.last == .init(name: "unmute", masking: false))
        await settle()
        #expect(!harness.echoGuard.isMasking)
    }

    @Test func aRaiseWithNothingBusyIsLoweredByTheBackstop() async {
        let harness = AmbientDuplexPlaybackTests.Harness()
        _ = harness.playback
        harness.echoGuard.setReplyAudible(true)
        harness.playback.toggleMute()
        await harness.quiet()
        #expect(!harness.echoGuard.isMasking)
    }

    @Test func voiceProcessingKeepsReplyPlaybackAtFullLevel() {
        #expect(!AmbientReplyEchoGuard.replyDucking.enableAdvancedDucking.boolValue)
        #expect(AmbientReplyEchoGuard.replyDucking.duckingLevel == .min)
    }
}

private func peak(_ buffer: AVAudioPCMBuffer) throws -> Float {
    let samples = try #require(buffer.floatChannelData?[0])
    return (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
}
