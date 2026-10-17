import Foundation
import Testing
@testable import HailCore

@Suite @MainActor struct AppleCoachingDisarmReentryTests {
    @Test(arguments: [false, true])
    func preBeginDisarmCannotOverwriteANewerStopOrBegin(replace: Bool) throws {
        let rig = try DisarmRig()
        var freshAdvice: AdmittedCoachingAdvice?
        rig.monitor.onDisarm = {
            if replace {
                do { freshAdvice = try rig.beginAdvice() } catch { Issue.record(error) }
            } else { rig.adapter.stop() }
        }
        #expect(throws: (any Error).self) {
            try rig.adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        }
        #expect(rig.capture.startCount == (replace ? 1 : 0) && rig.capture.stopCount == 0)
        if replace { try rig.adapter.resume(#require(freshAdvice)); #expect(rig.player.resumed == 1) } else {
            #expect(rig.monitor.observe() == .unqualified)
        }
        rig.adapter.stop()
    }

    @Test(arguments: [false, true])
    func retirementDisarmCannotStopACallbackCreatedSuccessor(invalidate: Bool) throws {
        let rig = try DisarmRig()
        _ = try rig.beginAdvice()
        var freshAdvice: AdmittedCoachingAdvice?
        rig.monitor.onDisarm = {
            do { freshAdvice = try rig.beginAdvice() } catch { Issue.record(error) }
        }
        if invalidate { rig.adapter.invalidate() } else { rig.adapter.stop() }
        #expect(rig.capture.startCount == 2 && rig.capture.stopCount == 1)
        try rig.adapter.resume(#require(freshAdvice))
        #expect(rig.player.resumed == 1)
        rig.adapter.stop()
    }
}

@MainActor private final class DisarmRig {
    let capture = FakeAudioCapture(), player = CoachingTestPlayer(), monitor = DisarmMonitor()
    let adapter: ApplePrivateCoaching
    init() throws {
        let now = ContinuousClock.now
        adapter = try ApplePrivateCoaching(capture: capture, player: player, monitor: monitor,
            listenerID: "private-coach", hooks: .init(buffer: { _, _ in }, suspended: { _, _ in }),
            clock: .init(now: { now }, schedule: { _, _ in {} }))
    }
    func beginAdvice() throws -> AdmittedCoachingAdvice {
        let lease = try adapter.begin(sessionID: UUID(), destinationID: UUID(), consentConfirmed: true)
        let advice = try adapter.admit(coachingWireData(lease))
        try adapter.schedule(coachingPCM, for: advice)
        return advice
    }
}

@MainActor private final class DisarmMonitor: CoachingOutputMonitoring {
    var onInvalidated: (() -> Void)?
    var onDisarm: (() -> Void)?
    private var token: UUID?
    func arm() throws { token = UUID() }
    func observe() -> CoachingOutputObservation {
        token.map { .verifiedHeadphones($0) } ?? .unqualified
    }
    func retains(_ token: UUID) -> Bool { self.token == token }
    func disarm() {
        token = nil
        let callback = onDisarm
        onDisarm = nil
        callback?()
    }
}
