import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Synthetic #935 coverage: only ambient buffers are masked; tap capture and reply routing keep their paths.
@MainActor
@Suite struct AmbientTapCaptureMaskTests {
    @Test(arguments: [false, true])
    func ambientSamplesAndSequenceContinueThroughTapAndTail(echoCancelled: Bool) async throws {
        let rig = TapMaskRig()
        rig.echoGuard.setRoutedThroughCapture(echoCancelled)
        rig.echoGuard.setReplyAudible(echoCancelled) // Echo-cancelled replies alone do not mask.
        #expect(!rig.echoGuard.isMasking)
        let source = FakeAudioCapture()
        let wrapped = rig.echoGuard.masking(source)
        var buffers = try wrapped.start().makeAsyncIterator()
        var encoder = try AmbientAudioEncoder(streamID: UUID())
        var payloads: [AudioPayload] = []
        for step in 0..<8 {
            if step == 1 { rig.ledger.begin(rig.owner) }
            if step == 4 { rig.ledger.end(rig.owner, resuming: true); rig.clock.advance(by: .milliseconds(399)) }
            if step == 5 { rig.clock.advance(by: .milliseconds(1)) }
            let original = try sineBuffer(offset: step * 4_800)
            try source.yield(original)
            let received = try #require(await buffers.next())
            let samples = try #require(received.pcmBuffer.floatChannelData?[0])
            let masked = (1...4).contains(step)
            #expect((0..<4_800).allSatisfy { samples[$0] == 0 } == masked)
            #expect(received.pcmBuffer.frameLength == original.frameLength)
            #expect(received.pcmBuffer.format == original.format)
            // The source's own samples, as used by a separate tap capture, were not modified.
            #expect(try #require(original.floatChannelData?[0])[12] != 0)
            payloads += try encoder.encode(received.pcmBuffer)
        }
        source.stop()
        #expect(await buffers.next() == nil)
        payloads += try encoder.finish()
        #expect(payloads.map(\.sequence) == Array(0..<payloads.count))
        #expect(payloads.count == 8)
        #expect(payloads.reduce(0) { $0 + $1.bytes.count } == 8 * AmbientAudioFormat.chunkBytes)
        #expect(payloads.filter(\.isFinal).count == 1)
    }

    @Test(arguments: [false, true])
    func overlapWaitsForBothReasonsAndTheirTails(tapEndsFirst: Bool) {
        let rig = TapMaskRig()
        rig.echoGuard.setReplyAudible(true)
        rig.ledger.begin(rig.owner)
        if tapEndsFirst { rig.ledger.end(rig.owner, resuming: true) } else { rig.echoGuard.setReplyAudible(false) }
        rig.clock.advance(by: .seconds(1))
        #expect(rig.echoGuard.isMasking)
        if tapEndsFirst { rig.echoGuard.setReplyAudible(false) } else { rig.ledger.end(rig.owner, resuming: true) }
        rig.clock.advance(by: .milliseconds(399))
        #expect(rig.echoGuard.isMasking)
        rig.clock.advance(by: .milliseconds(1))
        #expect(!rig.echoGuard.isMasking)
    }

    @Test func failedCaptureReleasesItsMask() {
        let rig = TapMaskRig()
        func failCapture() throws {
            rig.ledger.begin(rig.owner)
            defer { rig.ledger.end(rig.owner, resuming: true) }
            throw AudioCaptureError.alreadyRunning
        }
        #expect(throws: AudioCaptureError.alreadyRunning) { try failCapture() }
        #expect(rig.echoGuard.isMasking)
        rig.clock.advance(by: .milliseconds(400))
        #expect(!rig.echoGuard.isMasking)
    }

    @Test func cancelledCaptureReleasesItsMask() async {
        let rig = TapMaskRig()
        let capture = Task { @MainActor in
            rig.ledger.begin(rig.owner)
            defer { rig.ledger.end(rig.owner, resuming: true) }
            try await Task.sleep(for: .seconds(30))
        }
        await settle()
        #expect(rig.echoGuard.isMasking)
        capture.cancel()
        _ = await capture.result
        rig.clock.advance(by: .milliseconds(400))
        #expect(!rig.echoGuard.isMasking)
    }

    @Test func backgroundTeardownAndRepeatedEndDoNotExtendTail() {
        let rig = TapMaskRig()
        rig.ledger.begin(rig.owner)
        rig.ledger.markCleanupComplete(rig.owner)
        #expect(rig.playback.isCaptureSuppressed)
        rig.clock.advance(by: .milliseconds(300))
        rig.ledger.markCleanupComplete(rig.owner)
        rig.ledger.end(rig.owner, resuming: true)
        rig.clock.advance(by: .milliseconds(100))
        #expect(!rig.echoGuard.isMasking)
    }

    @Test func overlappingOwnersKeepMaskUntilLastCaptureEnds() {
        let rig = TapMaskRig()
        let second = UUID()
        rig.ledger.begin(rig.owner)
        rig.ledger.begin(second)
        rig.ledger.end(rig.owner, resuming: true)
        rig.clock.advance(by: .seconds(1))
        #expect(rig.echoGuard.isMasking)
        rig.ledger.end(second, resuming: true)
        rig.clock.advance(by: .milliseconds(400))
        #expect(!rig.echoGuard.isMasking)
    }

    @Test func missedEndIsHealedWithoutWaitingForAReplyOrSceneActivation() async throws {
        let rig = TapMaskRig()
        CapturePlaybackSuppression.begin(rig.owner, using: rig.playback) // No live capture behind this owner.
        #expect(rig.echoGuard.isMasking)
        try await waitUntil(timeout: .seconds(3)) { await !rig.playback.isCaptureSuppressed }
        #expect(!CapturePlaybackSuppression.hasLedger(for: rig.playback))
        rig.clock.advance(by: .milliseconds(400))
        #expect(!rig.echoGuard.isMasking)
    }

    @Test func diagnosticsUseExistingVocabularyAndOnlyRecordEdges() throws {
        let rig = TapMaskRig()
        let defaults = try #require(UserDefaults(suiteName: "AmbientTapCaptureMaskTests.\(UUID())"))
        defer { defaults.removeObject(forKey: DeviceDiagnostics.enabledKey) }
        let diagnostics = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        diagnostics.setEnabled(true)
        rig.echoGuard.diagnostics = diagnostics
        rig.ledger.begin(rig.owner)
        rig.ledger.begin(rig.owner)
        rig.ledger.end(rig.owner, resuming: true)
        rig.ledger.end(rig.owner, resuming: true)
        let events = try #require(diagnostics.nextBatch()).events.filter { $0.name == .echoGuard }
        #expect(events.count == 2)
        #expect(events.first?.fields == [.state: .token("tap_to_talk_start"), .on: .boolean(true)])
        #expect(events.last?.fields == [
            .state: .token("tap_to_talk_end"), .on: .boolean(false), .ms: .integer(400)
        ])
        for event in events {
            #expect(try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event)) == event)
        }
    }
}

@MainActor
private final class TapMaskRig {
    let clock = EchoGuardClock()
    let owner = UUID()
    let echoGuard: AmbientReplyEchoGuard
    let playback: ReplyPlaybackController
    let ledger: CaptureSuppressionLedger

    init() {
        let echoGuard = AmbientReplyEchoGuard(now: { [clock] in clock.now })
        let playback = ReplyPlaybackController(player: echoGuard.guarding(DuplexPlayer()))
        self.echoGuard = echoGuard
        self.playback = playback
        ledger = CaptureSuppressionLedger(playback: playback, isLive: { _ in true })
    }
}
