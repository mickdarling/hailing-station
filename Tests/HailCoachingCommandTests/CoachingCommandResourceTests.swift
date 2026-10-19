import Foundation
import HailCore
import Testing
@testable import haild

@Suite @MainActor struct CoachingCommandResourceTests {
    @Test(arguments: ["off", "quit", "permission lost"])
    func offReleasesPlaybackObserverBeforeTheNextAudioAllocation(control: String) async throws {
        let weakOwner = OwnerReference()
        let instant = ContinuousClock.now
        let clock = CoachingClock(now: { instant }, schedule: { _, _ in {} })
        var allocations = 0, priorReleased = false
        let command = try CoachingCommand(listener: "coach", transport: { _, _ in ResourceTransport() },
            audio: { hooks in
                if allocations == 1 { priorReleased = weakOwner.audio == nil }
                allocations += 1
                let owner = try ExecutablePrivateAudio(capture: ExecutableCoachingCapture(),
                    player: ExecutablePrivatePlayer(), hooks: hooks, clock: clock)
                weakOwner.audio = owner
                // The observer intentionally retains its resource, like the original native factory.
                return CoachingCommandAudio(owner: owner, playback: {
                    owner.session.qualification == nil ? .unavailable : .idle
                })
            }, speech: ExecutableMockSpeech(), clock: clock)
        _ = try command.control("enable aware")
        _ = try command.control(control)
        await command.join()
        #expect(weakOwner.audio == nil)
        _ = try command.control("enable aware")
        #expect(allocations == 2 && priorReleased)
        await command.join()
        #expect(weakOwner.audio == nil)
    }

    private final class OwnerReference { weak var audio: ExecutablePrivateAudio? }
    private final class ResourceTransport: ForegroundCoachingTransport {
        func send(_ control: ForegroundCoachingControl) -> Bool { true }
        func write(_ buffer: AudioCaptureBuffer) -> Bool { true }
        func close() {}
        func stop() async {}
    }
}
