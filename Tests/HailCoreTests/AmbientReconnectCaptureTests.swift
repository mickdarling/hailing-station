import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectCaptureTests {
    @Test func realEngineTapDiscardsGapBeforeYieldEvenThroughMaskingWrapper() async throws {
        let engine = CountingEngineOperations()
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: engine.operations)
        let echoGuard = AmbientReplyEchoGuard()
        let admission = AudioCaptureAdmission()
        let wrapped = echoGuard.masking(capture)
        let stream = try AudioCaptureAdmission.$current.withValue(admission) { try wrapped.start() }
        var iterator = stream.makeAsyncIterator()
        admission.setPaused(true)
        for _ in 0..<50 { engine.feed(try sineBuffer()) }
        admission.setPaused(false)
        let silent = try sineBuffer()
        let samples = try #require(silent.floatChannelData?[0])
        for index in 0..<4_800 { samples[index] = 0 }
        engine.feed(silent)
        capture.stop()
        let first = try #require(await iterator.next())
        #expect(first.admissionEpoch == admission.epoch)
        #expect((0..<4_800).allSatisfy { first.pcmBuffer.floatChannelData?[0][$0] == 0 })
        #expect(await iterator.next() == nil) // No gap buffer waited behind the sentinel.
        #expect(engine.starts == 1)
    }
    @Test func buffersWaitingBeforeConversionCannotEnterRenewedStream() async throws {
        let capture = FakeAudioCapture()
        let sent = SentAudio()
        let gate = SleepGate()
        let streamer = AmbientAudioStreamer(capture: capture, maxBacklogChunks: 10, makeStreamID: { UUID() },
                                             beforeEncode: { try? await gate.sleep(.zero) },
                                             send: { await sent.send($0) })
        try streamer.start()
        try capture.yield(sineBuffer())
        try await waitUntil { await gate.isWaiting() }
        streamer.suspendTransport()
        for _ in 0..<20 { try capture.yield(sineBuffer()) }
        streamer.resumeTransport()
        await gate.fire()
        capture.stop()
        await streamer.stop()
        #expect(await sent.payloads.isEmpty)
        #expect(capture.discardedCount == 20)
    }
    @Test func retainedCaptureStillMasksTapAndHealsMissedTapEndAfterRestore() async throws {
        let rig = try AmbientReconnectRig()
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(now: { clock.now })
        let playback = ReplyPlaybackController(player: echoGuard.guarding(DuplexPlayer()))
        rig.echoGuard = echoGuard
        try await rig.start()
        try await rig.drop()
        let owner = UUID()
        CapturePlaybackSuppression.begin(owner, using: playback)
        #expect(echoGuard.isMasking)
        try await rig.reconnect()
        let audio = try await rig.socket.sentFrames().compactMap { frame -> AudioPayload? in
            if case .audio(let audio) = frame.payload { return audio }; return nil
        }
        #expect(!audio.isEmpty && audio.allSatisfy { $0.bytes.allSatisfy { $0 == 0 } })
        #expect(rig.capture.startCount == 1)
        try await waitUntil(timeout: .seconds(3)) { await !playback.isCaptureSuppressed }
        clock.advance(by: .milliseconds(400))
        #expect(!echoGuard.isMasking)
        #expect(rig.controller.isListening)
        await rig.close()
    }
}
