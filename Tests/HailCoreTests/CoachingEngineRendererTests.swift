import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
final class CoachingRenderRig {
    var running = true
    var output = CoachingOutputObservation.verifiedHeadphones(UUID())
    var frames: [UInt32] = []
    var plays = 0
    var stops = 0
    var mutes: [Bool] = []
    var afterSchedule: (() -> Void)?
    lazy var renderer = CoachingEngineRenderer(operations: .init(ready: { self.running }, schedule: { buffer, _ in
        self.frames.append(buffer.frameLength)
        self.afterSchedule?()
    }, control: { command in
        switch command {
        case .play: self.plays += 1
        case .stop: self.stops += 1
        case .muted(let value): self.mutes.append(value)
        case .pause: break
        }
    }), observe: { self.output })
}

@Suite @MainActor struct CoachingEngineRendererTests {
    @Test func rendersBoundedPCMOnTheAlreadyRunningOwnerWithoutStartupOperation() throws {
        let rig = CoachingRenderRig()
        try rig.renderer.schedule(coachingPCM, onPlayed: nil)
        try rig.renderer.resume()
        rig.renderer.setMuted(false)
        #expect(rig.frames == [2] && rig.plays == 2 && rig.mutes == [false])
    }

    @Test func stoppedEngineAndUnknownOutputNeverScheduleResumeOrUnmute() {
        for running in [false, true] {
            let rig = CoachingRenderRig()
            rig.running = running
            if running { rig.output = .unqualified }
            #expect(throws: CoachingSafetyError.unsafeOutput) {
                try rig.renderer.schedule(coachingPCM, onPlayed: nil)
            }
            #expect(throws: CoachingSafetyError.unsafeOutput) { try rig.renderer.resume() }
            rig.renderer.setMuted(false)
            #expect(rig.frames.isEmpty && rig.plays == 0 && rig.mutes.isEmpty)
        }
    }

    @Test func routeNotificationWhileQueuingNeverStartsTheNode() {
        let rig = CoachingRenderRig()
        rig.afterSchedule = { rig.output = .unqualified }
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            try rig.renderer.schedule(coachingPCM, onPlayed: nil)
        }
        #expect(rig.frames == [2] && rig.plays == 0 && rig.stops > 0)
    }

    @Test func replacementRejectsMalformedOrUnboundedQueuesBeforeChangingPlayback() {
        let rig = CoachingRenderRig()
        let invalid = AudioPayload(codec: .pcm16, sampleRate: 48_000, channels: 1,
                                   sequence: 0, isFinal: true, bytes: Data([1, 0]))
        #expect(throws: CoachingSafetyError.invalidAudio) {
            try rig.renderer.replaceQueue(with: [coachingPCM, invalid], onPlayed: nil)
        }
        #expect(throws: CoachingSafetyError.queueFull) {
            try rig.renderer.replaceQueue(with: Array(repeating: coachingPCM, count: 33), onPlayed: nil)
        }
        #expect(rig.frames.isEmpty && rig.plays == 0 && rig.stops == 0)
    }
}
