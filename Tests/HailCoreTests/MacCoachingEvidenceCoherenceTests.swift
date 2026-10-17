#if os(macOS)
import Foundation
import Testing
@testable import HailCore

@MainActor @Suite struct MacCoachingEvidenceCoherenceTests {
    let expected = MacCoachingDeviceEvidence(deviceID: 20, uid: "authored-output", streams: [21])

    @Test func changedConstructorEvidenceIsRejectedBeforeSettingUnit() {
        for changed in [MacCoachingDeviceEvidence(deviceID: 20, uid: "authored-output", streams: [22]),
                        .init(deviceID: 20, uid: "replacement-output", streams: [21]),
                        .init(deviceID: 30, uid: "authored-output", streams: [21])] {
            var sets = 0
            #expect(throws: CoachingSafetyError.unsafeOutput) {
                _ = try ApplePrivateCoaching.bindPrivateOutput(expected, read: { changed },
                    operations: .init(running: { false }, setDevice: { _ in sets += 1 }, currentDevice: { 20 }))
            }
            #expect(sets == 0)
        }
    }

    @Test func matchingEvidenceRemainsFixedAndReplacementPermanentlyRetires() throws {
        var current: MacCoachingDeviceEvidence? = expected
        var sets = 0
        let binding = try ApplePrivateCoaching.bindPrivateOutput(expected, read: { current },
            operations: .init(running: { false }, setDevice: { _ in sets += 1 }, currentDevice: { 20 }))
        #expect(binding.isStillBound() && sets == 1)
        current = .init(deviceID: 20, uid: "authored-output", streams: [22])
        #expect(!binding.isStillBound())
        current = expected
        #expect(!binding.isStillBound() && sets == 1)
    }

    @Test func replacementDuringSetterCannotPublishBinding() {
        var current: MacCoachingDeviceEvidence? = expected
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            _ = try ApplePrivateCoaching.bindPrivateOutput(expected, read: { current },
                operations: .init(running: { false }, setDevice: { _ in
                    current = .init(deviceID: 20, uid: "authored-output", streams: [22])
                }, currentDevice: { 20 }))
        }
    }

    @Test func listenerUsesBindingSnapshotAndLossRetiresLatchImmediately() throws {
        let binding = try ApplePrivateCoaching.bindPrivateOutput(expected, read: { expected },
            operations: .init(running: { false }, setDevice: { _ in }, currentDevice: { 20 }))
        var callbacks: [UInt32: @Sendable () -> Void] = [:]
        let registrations = expected.streams.map { stream in
            MacCoachingPropertyRegistration(install: { handler in
                callbacks[stream] = handler
                return { callbacks[stream] = nil }
            })
        }
        let monitor = try MacCoachingOutputMonitor(bound: { binding.isStillBound() },
            registrations: registrations, center: NotificationCenter(), names: [])
        try monitor.arm()
        guard case .verifiedHeadphones(let token) = monitor.observe() else {
            Issue.record("Matching authored binding should arm"); return
        }
        let callback = try #require(callbacks[21])
        #expect(callbacks[22] == nil && monitor.retains(token))
        callback()
        #expect(!monitor.retains(token)) // No polling or actor cleanup is needed for revocation.
    }

    @Test func replacementBeforeListenerInstallationDeniesAndRemovesListeners() throws {
        var current: MacCoachingDeviceEvidence? = expected
        let binding = try ApplePrivateCoaching.bindPrivateOutput(expected, read: { current },
            operations: .init(running: { false }, setDevice: { _ in }, currentDevice: { 20 }))
        current = .init(deviceID: 20, uid: "authored-output", streams: [22])
        var removed = 0
        #expect(throws: CoachingSafetyError.unsafeOutput) {
            _ = try MacCoachingOutputMonitor(bound: { binding.isStillBound() }, registrations: [
                .init(install: { _ in { removed += 1 } })
            ], center: NotificationCenter(), names: [])
        }
        #expect(removed == 1 && !binding.isStillBound())
    }
}
#endif
