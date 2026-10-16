#if os(macOS)
import AVFAudio
import Foundation
@testable import HailCore

/// Original capture/owner/monitor classes; authored device evidence and engine operations only.
@MainActor final class MacCoachingInterruptionRig {
    let input = AVAudioEngine(), output = AVAudioEngine()
    let center = NotificationCenter(), workspace = NotificationCenter()
    let fake = CountingEngineOperations(), sleeper = SteppedSleeper()
    let time = ForegroundTestClock(), player = CoachingTestPlayer()
    let watchdog: Bool
    var outputRunning = false, safeBinding = true, buffers = 0
    var suspensions: [CoachingSuspension] = []
    init(watchdog: Bool = false) { self.watchdog = watchdog }
    lazy var capture = AVAudioEngineCapture(engine: input, notificationCenter: center,
        operations: fake.operations, stallPolicy: watchdog ? MacCoachingAudioOwner.privateCaptureStallPolicy : nil,
        now: { [sleeper] in sleeper.clock.now() }, sleep: { [sleeper] in try await sleeper.sleep($0) })
    lazy var owner = MacCoachingAudioOwner(
        input: .init(deviceID: 10, uid: "authored-room-mic", streams: [11]), capture: capture,
        output: .init(start: { [weak self] in self?.outputRunning = true },
                      stop: { [weak self] in self?.outputRunning = false },
                      running: { [weak self] in self?.outputRunning == true }),
        bound: { [weak self] in self?.safeBinding == true })
    func make(hooks: PrivateCoachingSession.Hooks? = nil) throws -> ApplePrivateCoaching {
        let owned = owner
        let monitor = try MacCoachingOutputMonitor(bound: { owned.isStillBound() },
            registrations: [.engine(input, center: center), .engine(output, center: center)],
            center: center, names: [], workspaceCenter: workspace)
        return try ApplePrivateCoaching(capture: owned, player: player, monitor: monitor,
            listenerID: "private-coach", hooks: .init(buffer: { [weak self] sample, lease in
                self?.buffers += 1; hooks?.buffer(sample, lease)
            }, suspended: { [weak self] lease, reason in
                self?.suspensions.append(reason); hooks?.suspended(lease, reason)
            }), clock: time.clock)
    }
}
#endif
