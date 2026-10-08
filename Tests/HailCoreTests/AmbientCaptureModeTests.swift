import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Choosing ambient capture from the output route (#343): voice processing pulled AirPods off A2DP, so headphone
/// routes capture without it, and every other route keeps the echo canceller.
struct AmbientCaptureModeTests {
    @Test func headphoneRoutesCaptureWithoutVoiceProcessing() {
        #expect(AmbientCaptureModeResolver.mode(for: [.bluetoothA2DP]) == .plain)
        #expect(AmbientCaptureModeResolver.mode(for: [.wiredHeadphones]) == .plain)
        #expect(AmbientCaptureModeResolver.mode(for: [.bluetoothLE]) == .plain)
    }

    @Test func builtInRoutesKeepVoiceProcessing() {
        #expect(AmbientCaptureModeResolver.mode(for: [.builtInSpeaker]) == .voiceProcessing)
        #expect(AmbientCaptureModeResolver.mode(for: [.builtInReceiver]) == .voiceProcessing)
    }

    @Test func anEmptyRouteKeepsVoiceProcessing() {
        #expect(AmbientCaptureModeResolver.mode(for: []) == .voiceProcessing)
    }

    @Test func aRouteThatAlsoPlaysAloudKeepsVoiceProcessing() {
        #expect(AmbientCaptureModeResolver.mode(for: [.bluetoothA2DP, .builtInSpeaker]) == .voiceProcessing)
        #expect(AmbientCaptureModeResolver.mode(for: [.wiredHeadphones, .hdmi]) == .voiceProcessing)
    }

    /// HFP is duplex, so voice processing works on it, and a car hands-free kit reports HFP too.
    @Test func onlyEarOnlyOutputsDropVoiceProcessing() {
        let plain = AudioOutputKind.allCases.filter { AmbientCaptureModeResolver.mode(for: [$0]) == .plain }
        #expect(Set(plain.map { "\($0)" }) == ["wiredHeadphones", "bluetoothA2DP", "bluetoothLE"])
        #expect(AmbientCaptureModeResolver.mode(for: [.bluetoothHFP]) == .voiceProcessing)
        #expect(AmbientCaptureModeResolver.mode(for: [.carAudio]) == .voiceProcessing)
        #expect(AmbientCaptureModeResolver.mode(for: [.other]) == .voiceProcessing)
    }

    @Test func modesHaveStableEnumeratedNames() {
        #expect(AmbientCaptureMode.allCases.map(\.rawValue) == ["vpio", "plain"])
    }
}

/// In plain mode replies never reach the capture engine, so the echo guard must silence the mic while one plays,
/// even with the "Mask mic while speaking" switch off.
@MainActor
@Suite struct AmbientPlainCaptureEchoGuardTests {
    @Test func plainCaptureUsesTheEngineCaptureItIsGiven() throws {
        let echoGuard = AmbientReplyEchoGuard()
        let engineCapture = FakeAudioCapture()
        let capture = try echoGuard.ambientCapture(mode: .plain, plainCapture: { _ in engineCapture })
        _ = try capture.start()
        #expect(engineCapture.startCount == 1)
        capture.stop()
        #expect(engineCapture.stopCount >= 1)
    }

    /// #356: replies play through the plain capture engine, so its output must be wired before it first starts.
    @Test func plainCaptureGetsAnEngineWiredForReplyOutput() throws {
        let echoGuard = AmbientReplyEchoGuard()
        var handed: AVAudioEngine?
        _ = try echoGuard.ambientCapture(mode: .plain, plainCapture: { engine in
            handed = engine
            return FakeAudioCapture()
        })
        let engine = try #require(handed)
        #expect(engine.inputConnectionPoint(for: engine.outputNode, inputBus: 0)?.node === engine.mainMixerNode)
    }

    /// A plain engine plays replies but cancels no echo, so routing through it never lowers masking.
    @Test func onlyAVoiceProcessingEngineCountsAsEchoCancelled() {
        #expect(CaptureReplyRouting.echoCancelled(cancelsEcho: true, routed: true))
        #expect(!CaptureReplyRouting.echoCancelled(cancelsEcho: false, routed: true))
        #expect(!CaptureReplyRouting.echoCancelled(cancelsEcho: true, routed: false))
    }

    @Test func plainCaptureSendsSilenceWhileAReplyIsAudible() async throws {
        let clock = EchoGuardClock()
        let echoGuard = AmbientReplyEchoGuard(tail: .milliseconds(400), now: { clock.now })
        echoGuard.masksDuringReplies = false
        let engineCapture = FakeAudioCapture()
        let sent = SentAudio()
        let capture = try echoGuard.ambientCapture(mode: .plain, plainCapture: { _ in engineCapture })
        let streamer = AmbientAudioStreamer(capture: capture, send: { await sent.send($0) })
        echoGuard.setReplyAudible(true)

        try streamer.start()
        #expect(!echoGuard.isEchoCancelling)
        #expect(echoGuard.isMasking)
        for block in 0..<4 { try engineCapture.yield(sineBuffer(offset: block * 4_800)) }
        try await waitUntil { await sent.payloads.count >= 2 }
        echoGuard.setReplyAudible(false)
        clock.advance(by: .milliseconds(400))
        #expect(!echoGuard.isMasking)
        for block in 4..<7 { try engineCapture.yield(sineBuffer(offset: block * 4_800)) }
        await streamer.stop()

        let payloads = await sent.payloads
        #expect(payloads.prefix(2).allSatisfy { $0.bytes.allSatisfy { $0 == 0 } })
        #expect(payloads.dropFirst(4).contains { $0.bytes.contains { $0 != 0 } })
    }

    /// haild times RightyO's follow-up window from these two events (#342), so plain capture must not move them.
    @Test func plainCaptureKeepsReplyPlaybackStartAndEndDiagnostics() async throws {
        let suite = "hail-plain-capture-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let clock = TestInstantClock()
        let log = DeviceDiagnostics(
            defaults: UserDefaults(suiteName: suite) ?? .standard, appInfo: [:], wallNow: { 1_000 },
            clock: { [clock] in clock.now() }
        )
        log.setEnabled(true)
        let harness = AmbientDuplexPlaybackTests.Harness()
        let engineCapture = FakeAudioCapture()
        let capture = try harness.echoGuard.ambientCapture(mode: .plain, plainCapture: { _ in engineCapture })
        let streamer = AmbientAudioStreamer(capture: capture, send: { _ in })
        try streamer.start()
        log.watch(harness.playback)

        harness.playback.ingest(duplexEvent())
        await settle()
        #expect(harness.echoGuard.isMasking)
        harness.player.finish()
        await settle()
        await streamer.stop()

        var names: [DiagnosticEventName] = []
        while let batch = log.nextBatch() {
            names += batch.events.map(\.name)
            clock.advance(by: .seconds(60))
        }
        #expect(names.filter { $0 == .replyPlaybackStart || $0 == .replyPlaybackEnd }
            == [.replyPlaybackStart, .replyPlaybackEnd])
    }
}
