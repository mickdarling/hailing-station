#if os(macOS)
import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct MacCoachingMonitorOwnershipTests {
    @Test(arguments: [2, 3])
    func stoppedStartupCannotAdmitCaptureOrPublishStream(atObservation: Int) throws {
        let capture = FakeAudioCapture()
        var running = false
        var reads = 0
        var owner: MacCoachingAudioOwner?
        owner = .init(input: .init(deviceID: 10, uid: "authored-room-input", streams: [11]), capture: capture,
            output: .init(start: { running = true }, stop: { running = false }, running: { running }), bound: {
                reads += 1
                if reads == atObservation { owner?.stop() }
                return true
            })
        let active = try #require(owner)
        #expect(throws: CoachingSafetyError.unsafeOutput) { _ = try active.start() }
        #expect(capture.startCount == (atObservation == 2 ? 0 : 1))
        #expect(!running && capture.stopCount == 1)
        owner = nil
    }

    @Test func ownerStartingDuringInitialObservationCannotBeStartedAgain() {
        let capture = FakeAudioCapture()
        var running = false
        var starts = 0
        let owner = MacCoachingAudioOwner(
            input: .init(deviceID: 10, uid: "authored-room-input", streams: [11]), capture: capture,
            output: .init(start: { starts += 1; running = true }, stop: { running = false }, running: { running }),
            bound: { running = true; return true })
        #expect(throws: CoachingSafetyError.unsafeOutput) { _ = try owner.start() }
        #expect(starts == 0 && capture.startCount == 0)
    }

    @Test(arguments: [false, true])
    func rejectedOldBindingObservationCannotRetireNewArm(arming: Bool) throws {
        var reenter: (() -> Void)?
        let monitor = try MacCoachingOutputMonitor(bound: {
            guard let callback = reenter else { return true }
            reenter = nil
            callback()
            return false // Invalid evidence belongs only to the superseded observation.
        }, registrations: [], center: NotificationCenter(), names: [])
        try monitor.arm()
        reenter = { do { try monitor.arm() } catch { Issue.record(error) } }
        if arming {
            #expect(throws: CoachingSafetyError.unsafeOutput) { try monitor.arm() }
        } else {
            #expect(monitor.observe() == .unqualified)
        }
        #expect(monitor.observe() != .unqualified)
    }

    @Test func releasedAudioOwnerStopsOnlyItsStartedResources() throws {
        let capture = FakeAudioCapture()
        var running = false
        var stopped = 0
        var owner: MacCoachingAudioOwner? = .init(
            input: .init(deviceID: 10, uid: "authored-room-input", streams: [11]), capture: capture,
            output: .init(start: { running = true }, stop: { stopped += 1; running = false },
                          running: { running }), bound: { true })
        _ = try owner?.start()
        #expect(running && capture.startCount == 1)
        owner = nil
        #expect(!running && stopped == 1 && capture.stopCount == 1)
    }

    @Test func partialListenerFailureAndInitialBindingFailureRemoveOwnedListeners() {
        for failsDuringInstall in [false, true] {
            var installed = 0
            var removed = 0
            let first = MacCoachingPropertyRegistration(install: { _ in
                installed += 1
                return { removed += 1 }
            })
            let second = MacCoachingPropertyRegistration(install: { _ in
                if failsDuringInstall { throw CoachingSafetyError.unsafeOutput }
                installed += 1
                return { removed += 1 }
            })
            #expect(throws: CoachingSafetyError.unsafeOutput) {
                _ = try MacCoachingOutputMonitor(bound: { false }, registrations: [first, second],
                    center: NotificationCenter(), names: [])
            }
            #expect(installed == (failsDuringInstall ? 1 : 2) && removed == installed)
        }
    }

    @Test func deinitRemovesListenersAndDelayedPropertyCleanupHasNoOwner() async throws {
        var removed = 0
        var invalidated = 0
        var handler: (@Sendable () -> Void)?
        var monitor: MacCoachingOutputMonitor? = try .init(bound: { true }, registrations: [
            .init(install: { callback in handler = callback; return { removed += 1 } })
        ], center: NotificationCenter(), names: [])
        monitor?.onInvalidated = { invalidated += 1 }
        try monitor?.arm()
        weak var released = monitor
        let callback = try #require(handler)
        callback()
        monitor = nil
        await drainCoachingTasks()
        callback()
        await drainCoachingTasks()
        #expect(released == nil && removed == 1 && invalidated == 0)
        released = nil
    }
}
#endif
