import Foundation
import HailCore
import Testing
@testable import haild

@Suite @MainActor struct CoachingCommandTests {
    @Test func defaultOffStatusAndUnknownControlsCannotConstructRuntime() async throws {
        let rig = try Rig()
        #expect(rig.command.owner.status == .off && rig.created == 0)
        #expect(try rig.command.control("status"))
        #expect(try rig.command.control("off"))
        for input in ["enable", "enable true", "owner idle", "quoted enable aware", "{\"action\":\"enable\"}"] {
            #expect(throws: (any Error).self) { try rig.command.control(input) }
        }
        await rig.command.join()
        #expect(rig.created == 0 && rig.speech.calls == 0)
    }
    @Test func explicitAwareEnableAndSeparateTrustedActivityUseSameOwner() async throws {
        let rig = try Rig()
        #expect(try rig.command.control("enable aware"))
        #expect(rig.created == 1 && rig.command.owner.status == .active)
        #expect(rig.flags?()?.ownerMidAnswer == true)
        #expect(try rig.command.control("owner idle"))
        #expect(rig.flags?()?.ownerMidAnswer == false && rig.flags?()?.playback == false)
        rig.playback = .pending
        #expect(rig.flags?()?.playback == true)
        rig.playback = .unavailable
        #expect(rig.flags?() == nil)
        #expect(try rig.command.control("owner answering"))
        rig.playback = .idle
        #expect(rig.flags?()?.ownerMidAnswer == true)
        try rig.capture.send(tone: true)
        // Yield count is not evidence that the capture consumer delivered this buffer.
        let deliveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while rig.transport.writes == 0, ContinuousClock.now < deliveryDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.transport.writes == 1)
        await rig.command.join()
        #expect(rig.capture.stops == 1 && rig.transport.stops == 1)
    }
    @Test func offLossInvalidAndQuitRetireAndFreshRunResetsBusyObservation() async throws {
        for control in ["off", "awareness lost", "permission lost", "quit", "not a local control", "enable aware"] {
            let rig = try Rig()
            _ = try rig.command.control("enable aware")
            _ = try rig.command.control("owner idle")
            _ = try? rig.command.control(control)
            await rig.command.join()
            #expect(rig.command.owner.status == .off && rig.capture.stops == 1 && rig.transport.stops == 1)
            _ = try rig.command.control("enable aware")
            #expect(rig.flags?()?.ownerMidAnswer == true && rig.created == 2)
            await rig.command.join()
        }
    }

    private final class Transport: ForegroundCoachingTransport {
        var writes = 0, stops = 0
        func send(_ control: ForegroundCoachingControl) -> Bool { true }
        func write(_ buffer: AudioCaptureBuffer) -> Bool { writes += 1; return true }
        func close() {}
        func stop() async { stops += 1 }
    }
    @MainActor private final class Rig {
        let capture = ExecutableCoachingCapture(), player = ExecutablePrivatePlayer(), speech = ExecutableMockSpeech()
        let transport = Transport()
        var playback: CoachingPlaybackObservation = .idle
        var flags: (() -> CoachingActivityFlags?)?
        var created = 0
        private var controller: CoachingCommand?
        var command: CoachingCommand {
            guard let controller else { preconditionFailure("Authored fixture incomplete") }; return controller
        }
        init() throws {
            // This suite checks local controls and delivery, not real-time lease expiry.
            let instant = ContinuousClock.now
            let clock = CoachingClock(now: { instant }, schedule: { _, _ in {} })
            controller = try CoachingCommand(listener: "coach", transport: { [unowned self] _, flags in
                created += 1; self.flags = flags; return transport
            }, audio: { [unowned self] hooks in
                let owner = try ExecutablePrivateAudio(capture: capture, player: player, hooks: hooks, clock: clock)
                return CoachingCommandAudio(owner: owner, playback: { [unowned self] in playback })
            }, speech: speech, clock: clock)
        }
    }
}
