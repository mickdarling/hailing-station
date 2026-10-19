import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// #269: actual capture/composition lifecycle, injected engine operations only; no microphone IO.
@Suite @MainActor struct AppleCoachingProductionCaptureTests {
    @Test func immediateBeginKeepsReplacementCaptureAndAdviceAlive() async throws {
        let rig = AppleCoachingRig()
        let fake = CountingEngineOperations()
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: fake.operations)
        let player = CoachingEngineRenderer(operations: .init(ready: { fake.running }, schedule: { buffer, _ in
            rig.frameCounts.append(buffer.frameLength)
        }, control: { command in
            if case .play = command { rig.plays += 1 }
        }), observe: { rig.monitor.observe() })
        let adapter = try ApplePrivateCoaching(capture: capture, player: player, monitor: rig.monitor,
                                               listenerID: "private-coach", hooks: .init(buffer: { _, _ in
            rig.captureBuffers += 1
        }, suspended: { _, reason in rig.suspensions.append(reason) }), clock: rig.time.clock)
        let old = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let fresh = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        #expect(old.generation != fresh.generation)
        await drainCoachingTasks()
        #expect(fake.running && fake.starts == 2 && fake.stops == 1 && fake.tap != nil)
        fake.feed(try sineBuffer())
        await drainCoachingTasks()
        let advice = try adapter.admit(coachingWireData(fresh))
        try adapter.schedule(coachingPCM, for: advice)
        #expect(rig.captureBuffers == 1 && rig.frameCounts == [2] && rig.plays == 1)
        #expect(rig.suspensions == [.stopped])
        adapter.stop()
    }
}
