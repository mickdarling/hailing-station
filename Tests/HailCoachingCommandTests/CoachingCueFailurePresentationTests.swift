import Foundation
import HailCore
import Testing
@testable import HailCoaching

@MainActor private final class CueFailureCommand: LocalCoachingControlling {
    var status = ForegroundCoachingStatus.off
    var speechFailure: CoachingSpeechFailure?
    var stops = 0
    func control(_ line: String) throws -> Bool { status = .active; return true }
    func off() { stops += 1; status = .off }
    func join() async {}
}

@Suite @MainActor struct CoachingCueFailurePresentationTests {
    @Test func budgetFailureReportsFixedMessageAndKeepsListeningThenClearsOnNextOpportunity() async throws {
        let command = CueFailureCommand()
        let controller = LocalCoachingController(makeCommand: { _ in command })
        try controller.start(arguments: [], participantAwareness: true)
        command.speechFailure = .renderTimedOut
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.lastFailure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state == .active && command.stops == 0)
        #expect(controller.lastFailure == .cue(.renderTimedOut))
        #expect(controller.lastFailure?.message == "A coaching cue took too long to prepare. Still listening.")
        command.speechFailure = nil
        while controller.lastFailure != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.lastFailure == nil && controller.state == .active)
        command.speechFailure = .durationExceeded
        while controller.lastFailure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.lastFailure == .cue(.durationExceeded))
        await controller.stop()
        #expect(controller.state == .off && command.stops == 1)
        #expect(controller.lastFailure == nil)
    }

    @Test func cueReasonsNeverExposeProviderOutputOrRequireRestart() {
        for failure in [CoachingSpeechFailure.invalidPCM, .durationExceeded, .renderTimedOut] {
            let message = LocalCoachingController.Failure.cue(failure).message
            #expect(message.hasSuffix("Still listening.") && !message.contains("start again"))
        }
    }
}
