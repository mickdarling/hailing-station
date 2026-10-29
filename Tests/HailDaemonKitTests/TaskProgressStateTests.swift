import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct TaskProgressStateTests {
    let start = ContinuousClock.now
    func at(_ seconds: Int) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }
    func task() -> TaskProgressTask { .init(session: "work", binding: "current-binding") }
    func available() -> TaskProgressEnvironment {
        var value = TaskProgressEnvironment()
        value.connected = true
        value.listening = true
        value.uniqueRecipient = true
        return value
    }
    func active() -> TaskProgressState {
        var state = TaskProgressState()
        state.observe(available(), at: start)
        _ = state.start(task(), interval: .seconds(60), at: start)
        return state
    }

    @Test func exactDeadlineAndOneOutstandingEvenWhenVeryLate() throws {
        var state = active()
        let beforeDeadline = state.due(at: at(59))
        #expect(beforeDeadline == nil)
        let dueWake = state.due(at: at(60))
        let wake = try #require(dueWake)
        let whileOutstanding = state.due(at: at(3_600))
        #expect(whileOutstanding == nil)
        #expect(state.snapshot.pauseReason == .outstanding)
        let completed = state.complete(wake, at: at(3_600))
        #expect(completed)
        #expect(state.snapshot.nextDue == at(3_660))
        let beforeNextDeadline = state.due(at: at(3_659))
        #expect(beforeNextDeadline == nil)
        let atNextDeadline = state.due(at: at(3_660))
        #expect(atNextDeadline != nil)
    }

    @Test func ownerIntervalAndPauseCannotBeOverriddenByAgent() {
        var state = active()
        let agentInterval = state.agent(interval: .seconds(90), at: at(10))
        #expect(agentInterval == .applied)
        #expect(state.snapshot.nextDue == at(100))
        let ownerInterval = state.owner(.interval(.seconds(120)), at: at(20))
        #expect(ownerInterval == .applied)
        let agentOverride = state.agent(interval: .seconds(15), at: at(30))
        #expect(agentOverride == .ownerControlled)
        #expect(state.snapshot.interval == .seconds(120))
        #expect(state.snapshot.nextDue == at(140))
        #expect(state.snapshot.setByOwner)
        let paused = state.owner(.pause, at: at(40))
        #expect(paused == .applied)
        let pausedOverride = state.agent(interval: .seconds(30), at: at(50))
        #expect(pausedOverride == .ownerControlled)
        #expect(state.snapshot.pauseReason == .ownerPaused)
        let whilePaused = state.due(at: at(500))
        #expect(whilePaused == nil)
        let resumed = state.owner(.resume, at: at(500))
        #expect(resumed == .applied)
        #expect(state.snapshot.nextDue == at(620))
    }

    @Test func relativeOwnerControlsClampAndOwnerStopNeedsOwnerResume() {
        var state = active()
        _ = state.owner(.moreOften, at: at(1))
        #expect(state.snapshot.interval == .seconds(30))
        for _ in 0..<10 { _ = state.owner(.moreOften, at: at(2)) }
        #expect(state.snapshot.interval == TaskProgressState.minimumInterval)
        for _ in 0..<10 { _ = state.owner(.lessOften, at: at(3)) }
        #expect(state.snapshot.interval == TaskProgressState.maximumInterval)
        _ = state.owner(.stop, at: at(4))
        #expect(state.snapshot.pauseReason == .ownerStopped)
        #expect(state.snapshot.nextDue == nil)
        let stoppedOverride = state.agent(interval: .seconds(30), at: at(5))
        #expect(stoppedOverride == .ownerControlled)
        state.observe(available(), at: at(6))
        let withoutLiveCadence = state.due(at: at(10_000))
        #expect(withoutLiveCadence == nil)
        _ = state.owner(.resume, at: at(10_000))
        #expect(state.snapshot.nextDue == at(13_600))
    }

    @Test func everyDeliveryPauseDropsTicksAndResumesWithoutCatchup() {
        let reasons: [TaskProgressPauseReason] = [
            .privacy, .quiet, .media, .ownerSpeaking, .playback, .disconnected, .notListening, .ambiguousRecipient
        ]
        for reason in reasons {
            var state = active()
            var value = available()
            switch reason {
            case .privacy: value.privateMode = true
            case .quiet: value.quiet = true
            case .media: value.media = true
            case .ownerSpeaking: value.ownerSpeaking = true
            case .playback: value.playback = true
            case .disconnected: value.connected = false
            case .notListening: value.listening = false
            case .ambiguousRecipient: value.uniqueRecipient = false
            default: Issue.record("unexpected pause reason")
            }
            state.observe(value, at: at(30))
            #expect(state.snapshot.pauseReason == reason)
            #expect(state.snapshot.nextDue == nil)
            let pausedDeadline = state.due(at: at(6_000))
            #expect(pausedDeadline == nil)
            state.observe(available(), at: at(6_000))
            #expect(state.snapshot.nextDue == at(6_060))
            let resumedDeadline = state.due(at: at(6_000))
            #expect(resumedDeadline == nil)
        }
    }

    @Test func privateResponseCannotDeliverAndOldResponseCannotClearReplacement() throws {
        var state = active()
        let oldDue = state.due(at: at(60))
        let old = try #require(oldDue)
        var privateState = available()
        privateState.privateMode = true
        state.observe(privateState, at: at(61))
        #expect(!state.permits(old))
        #expect(state.snapshot.outstanding == old, "pause must not solicit again while the session is still busy")
        state.observe(available(), at: at(120))
        let stillOutstanding = state.due(at: at(180))
        #expect(stillOutstanding == nil)
        let replacement = task()
        let replaced = state.start(replacement, interval: .seconds(60), at: at(120))
        #expect(replaced)
        let replacementDue = state.due(at: at(180))
        let current = try #require(replacementDue)
        let staleCompletion = state.complete(old, at: at(181))
        #expect(!staleCompletion)
        #expect(state.snapshot.outstanding == current)
        state.finish(task: old.task.id)
        #expect(state.snapshot.task == replacement)
        let currentCompletion = state.complete(current, at: at(182))
        #expect(currentCompletion)
    }

    @Test func finishInvalidEnrollmentAndInvalidIntervalsNeverWake() {
        var state = active()
        let invalidOwnerInterval = state.owner(.interval(.zero), at: at(1))
        #expect(invalidOwnerInterval == .invalidInterval)
        let invalidAgentInterval = state.agent(interval: .seconds(3_601), at: at(2))
        #expect(invalidAgentInterval == .invalidInterval)
        let invalidEnrollment = state.start(.init(session: "", binding: "binding"), at: at(3))
        #expect(!invalidEnrollment)
        #expect(state.snapshot.nextDue == at(60))
        let id = state.task?.id
        if let id { state.finish(task: id) }
        let withoutLiveCadence = state.due(at: at(10_000))
        #expect(withoutLiveCadence == nil)
        #expect(state.snapshot.nextDue == nil)
        let idleAgentControl = state.agent(interval: .seconds(60), at: at(4))
        #expect(idleAgentControl == .noTask)
        let idleOwnerControl = state.owner(.resume, at: at(4))
        #expect(idleOwnerControl == .noTask)
    }
}
