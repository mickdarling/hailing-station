import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #904 ask 3: scripted sockets and synthetic capture. No physical/background/haptic proof.
@MainActor
@Suite(.serialized) struct AmbientReconnectTests {
    @Test(arguments: [AmbientScene.active, .background])
    func backgroundDropRestoresSameCaptureWithoutSceneChange(scene: AmbientScene) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let old = try rig.currentBinding()
        await rig.controller.update(binding: old, scene: scene)
        try await rig.drop()
        await rig.controller.update(binding: nil, scene: scene)
        #expect(rig.controller.isListening && rig.controller.isOn)
        #expect(rig.capture.stopCount == 0)
        try await rig.reconnect()
        #expect(rig.controller.isListening && rig.controller.isOn)
        #expect(rig.capture.startCount == 1 && rig.makeCalls == 1 && rig.permissionCalls == 1)
        #expect(rig.controller.binding != old)
        #expect(rig.notices.map(\.outcome) == [.applied]) // The app's haptic hook, once even on success.
        #expect(rig.notices[0].text.contains("listening resumed"))
        let audio = try await rig.socket.sentFrames().compactMap { frame -> AudioPayload? in
            if case .audio(let audio) = frame.payload { return audio }; return nil
        }
        #expect(audio.first?.sequence == 0 && audio.first?.isResume == true)
        await rig.close()
    }
    @Test func gapFramesAreDiscardedAtCaptureAndNeverForwardedAfterRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.feed()
        try await waitUntil { try await rig.socket.sentFrames().contains { if case .audio = $0.payload {
            return true
        }; return false } }
        let old = try #require(try await rig.socket.sentFrames().first { if case .audio = $0.payload {
            return true
        }; return false })
        try await rig.drop()
        for _ in 0..<100 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == 100)
        try await rig.reconnect()
        let frames = try await rig.socket.sentFrames().compactMap { frame -> AudioPayload? in
            if case .audio(let audio) = frame.payload { return audio }; return nil
        }
        if case .audio(let previous) = old.payload { #expect(frames.allSatisfy { $0.streamID != previous.streamID }) }
        #expect(frames.count <= 5) // Only the six post-restore buffers, less the renewal buffer and encoder hold.
        await rig.close()
    }
    @Test func longOutageRetainsCaptureAndReconnectsWithoutGivingUp() async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.drop()
        clock.advance(by: .seconds(3_600))
        #expect(rig.controller.reconnect.status == "Reconnecting…")
        #expect(rig.controller.isOn && rig.controller.isListening && rig.released == 0)
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.applied])
        #expect(rig.controller.reconnect.status == nil && rig.capture.startCount == 1)
        await rig.close()
    }
    @Test func flappingReportsEachDropOnceWithoutRestartLoops() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        for _ in 0..<2 { try await rig.drop(); try await rig.reconnect() }
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount == 0)
        #expect(rig.notices.map(\.outcome) == [.applied, .applied])
        for _ in 0..<3 { rig.controller.reconnect.restore(store: rig.store) }
        #expect(rig.notices.count == 2)
        await rig.close()
    }
    @Test func offOrRelaunchedControllerHasNoRecoveryIntent() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        try await rig.drop()
        try await rig.reconnect()
        #expect(!rig.controller.isOn && rig.capture.startCount == 0 && rig.notices.isEmpty)
        #expect(!AmbientListeningControllerTests.Harness().controller.reconnect.isPending)
        await rig.close()
    }
    @Test func cardDisappearanceIsNotAnOwnerStopAndRealDestinationLossStillNotifies() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        await rig.controller.destinationLost()
        #expect(rig.controller.isOn && rig.unexpected.isEmpty)
        try await rig.reconnect()
        await rig.controller.destinationLost()
        #expect(!rig.controller.isOn && rig.unexpected.count == 1)
        await rig.close()
    }
}
