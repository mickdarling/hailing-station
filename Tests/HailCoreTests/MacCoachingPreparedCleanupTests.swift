#if os(macOS)
import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// #524: a refused startup can retire after tap preparation, before owner.start ever runs.
@Suite @MainActor struct MacCoachingPreparedCleanupTests {
    @Test(arguments: [false, true], [false, true])
    func abandonedExistingConnectionReleasesItsPreparedTapCapability(started: Bool, explicitlyStopped: Bool) throws {
        let fake = CountingEngineOperations()
        weak var released: AVAudioEngineCapture?
        try configureAndAbandon(fake, started: started, explicitlyStopped: explicitlyStopped, released: &released)
        #expect(released == nil)
        #expect(fake.tap == nil && !fake.running && fake.starts == (started ? 1 : 0) && fake.stops == 1)
    }

    private func configureAndAbandon(_ fake: CountingEngineOperations, started: Bool, explicitlyStopped: Bool,
                                     released: inout AVAudioEngineCapture?) throws {
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                          operations: fake.operations)
        released = capture
        try capture.prepareTap()
        var outputRunning = false
        let owner = MacCoachingAudioOwner(
            input: .init(deviceID: 10, uid: "authored-room-mic", streams: [11]), capture: capture,
            output: .init(start: { outputRunning = true }, stop: { outputRunning = false },
                          running: { outputRunning }), bound: { true })
        let stream = started ? try owner.start() : nil
        if explicitlyStopped { owner.stop() }
        withExtendedLifetime((owner, stream)) {}
    }
}
#endif
