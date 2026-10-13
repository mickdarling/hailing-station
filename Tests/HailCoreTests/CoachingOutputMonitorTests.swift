import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct CoachingOutputMonitorTests {
    private let event = Notification.Name("SyntheticCoachingRouteEvent")
    private let wired = CoachingObservedPort(uid: "synthetic-wired-output", kind: .wiredHeadphones)

    @Test func disabledAndBluetoothAreUnqualifiedRegardlessOfTransport() throws {
        for kind in AudioOutputKind.allCases {
            let monitor = CoachingOutputMonitor(snapshot: { [.init(uid: "authored-output", kind: kind)] },
                                                center: NotificationCenter(), names: [])
            #expect(monitor.observe() == .unqualified)
            if kind == .wiredHeadphones {
                try monitor.arm()
                #expect(monitor.observe() != .unqualified)
            } else {
                #expect(throws: CoachingSafetyError.unsafeOutput) { try monitor.arm() }
                #expect(monitor.observe() == .unqualified)
            }
        }
    }

    @Test func emptyMultipleAndAnonymousPortsNeverQualify() {
        for ports in [[], [wired, wired], [.init(uid: "", kind: AudioOutputKind.wiredHeadphones)]] {
            let monitor = CoachingOutputMonitor(snapshot: { ports }, center: NotificationCenter(), names: [])
            #expect(throws: CoachingSafetyError.unsafeOutput) { try monitor.arm() }
        }
    }

    @Test func observedReplacementRetiresEvenWithoutNotificationAndCannotRevive() throws {
        var outputs = [wired]
        let monitor = CoachingOutputMonitor(snapshot: { outputs }, center: NotificationCenter(), names: [])
        try monitor.arm()
        let old = monitor.observe()
        outputs = [.init(uid: "another-synthetic-port", kind: .wiredHeadphones)]
        #expect(monitor.observe() == .unqualified)
        outputs = [wired]
        #expect(monitor.observe() == .unqualified)
        try monitor.arm()
        #expect(monitor.observe() != old && monitor.observe() != .unqualified)
    }

    @Test func notificationFencesImmediatelyBeforeActorTeardownAndOldEventCannotRetireNewArm() async throws {
        let center = NotificationCenter()
        let monitor = CoachingOutputMonitor(snapshot: { [self.wired] }, center: center, names: [event])
        var invalidations = 0
        monitor.onInvalidated = { invalidations += 1 }
        try monitor.arm()
        let old = monitor.observe()
        center.post(name: event, object: nil)
        #expect(monitor.observe() == .unqualified && invalidations == 0)
        try monitor.arm()
        #expect(monitor.observe() != old)
        await drainCoachingTasks()
        #expect(invalidations == 0 && monitor.observe() != .unqualified)
        center.post(name: event, object: nil)
        await drainCoachingTasks()
        #expect(invalidations == 1 && monitor.observe() == .unqualified)
    }

    @Test func notificationInsideArmSnapshotCannotProduceAQualifiedObservation() {
        let center = NotificationCenter()
        let monitor = CoachingOutputMonitor(snapshot: {
            center.post(name: self.event, object: nil)
            return [self.wired]
        }, center: center, names: [event])
        #expect(throws: CoachingSafetyError.unsafeOutput) { try monitor.arm() }
        #expect(monitor.observe() == .unqualified)
    }

    @Test func offActorNotificationRetiresBeforeReturningToMainActor() async throws {
        let center = NotificationCenter()
        let monitor = CoachingOutputMonitor(snapshot: { [self.wired] }, center: center, names: [event])
        try monitor.arm()
        let name = event
        await Task.detached { center.post(name: name, object: nil) }.value
        #expect(monitor.observe() == .unqualified)
    }
}
