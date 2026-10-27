import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Device-side fake-host proof only; no physical microphone, real host pre-arm, or haptic delivery is claimed.
@MainActor
@Suite(.serialized) struct AmbientReconnectPrivacyTests {
    @Test(arguments: [false, true])
    func knownPrivacyReassertsBeforeResumeWithOrWithoutPark(parked: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        let old = rig.controller.binding
        try await rig.drop()
        let host = try await rig.privateReconnect(parked: parked)
        #expect(rig.controller.reconnect.isPending && rig.controller.binding == old)
        try rig.discardWhileWaiting()
        try await rig.expectNoRestoredPCM()
        await #expect(host.audioBeforeConfirmation() == 0)
        try await host.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != old } }
        #expect(rig.store.privacySwitch(rig.endpoint.id).isPrivate)
        try await rig.feed()
        let frames = try await rig.socket.sentFrames()
        let request = try #require(frames.firstIndex { $0.payload == .control(.setPrivacy(on: true)) })
        let audio = try #require(frames.firstIndex { if case .audio = $0.payload { return true }; return false })
        #expect(request < audio)
        if case .audio(let first) = frames[audio].payload { #expect(first.isResume && first.sequence == 0) }
        await #expect(host.audioBeforeConfirmation() == 0)
        #expect(rig.notices.map(\.outcome) == [.applied])
        await host.expectExactlyOnePrivacyOn()
        // Reassertion did not latch an owner veto: the next drop can recover, too.
        try await rig.drop()
        let next = try await rig.privateReconnect()
        let restored = rig.controller.binding
        try await next.answer()
        try await waitUntil { await MainActor.run { rig.controller.binding != restored } }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied, .applied])
        await next.expectExactlyOnePrivacyOn()
        await rig.close()
    }

    @Test func nonConfirmingHostTimesOutWithoutPCMAndCallsStoppedHapticHookOnce() async throws {
        let rig = try AmbientReconnectRig()
        let timeout = SleepGate()
        rig.controller.reconnect.sleep = { delay in
            if delay == .seconds(5) { try await timeout.sleep(delay) }
            else { try await Task.sleep(for: delay) }
        }
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        try await rig.drop()
        let host = try await rig.privateReconnect(response: .silent)
        try await waitUntil { await timeout.isWaiting() }
        try rig.discardWhileWaiting()
        try await rig.expectNoRestoredPCM()
        await timeout.fire() // Injected 5 s confirmation timeout; no real 5 s wait.
        try await rig.expectStopped(.privacy, outcome: .failed)
        #expect(rig.notices.count == 1) // onNotice is the app's stopped notice/haptic hook.
        try await rig.expectNoRestoredPCM()
        await #expect(host.audioBeforeConfirmation() == 0)
        try await rig.socket.push(.duckMode(on: true)) // Late confirmation cannot reopen capture.
        #expect(!rig.controller.isOn && rig.capture.startCount == 1)
        await host.expectExactlyOnePrivacyOn()
        await rig.close()
    }

    @Test(arguments: [AmbientPrivacyHost.Response.off, .refuse, .requestRefusal, .expired, .sendFailure])
    func rejectionFailsClosedWithoutPCM(response: AmbientPrivacyHost.Response) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        try await rig.drop()
        let host = try await rig.privateReconnect(response: response)
        try await host.answer()
        try await rig.expectStopped(response == .refuse ? .nonTransport : .privacy,
                                    outcome: response == .refuse ? .blocked : .failed)
        #expect(rig.notices.count == 1) // Same stopped notice/haptic hook for each failure.
        try await rig.expectNoRestoredPCM()
        await #expect(host.audioBeforeConfirmation() == 0)
        await host.expectExactlyOnePrivacyOn()
        await rig.close()
    }

    @Test(arguments: [true, false])
    func ownerPrivacyTapWhileAwaitingConfirmationVetoesAndLatches(on: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        try await rig.drop()
        let host = try await rig.privateReconnect()
        try await rig.store.setPrivacy(on: on, host: rig.endpoint.id)
        try await rig.expectStopped(.privacy)
        try await host.answer()
        rig.controller.reconnect.restore(store: rig.store)
        try await rig.expectNoRestoredPCM()
        #expect(rig.notices.count == 1 && rig.capture.startCount == 1)
        await rig.close()
    }
}
