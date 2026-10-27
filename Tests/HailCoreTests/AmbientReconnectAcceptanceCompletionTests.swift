import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAcceptanceSettlingTests {
    @Test func acceptedStreamRefusalBeforeSenderContinuationResumesUsesOrdinaryStop() async throws {
        let rig = try AmbientReconnectRig()
        let delivery = SleepGate()
        let store = rig.store
        rig.controller = AmbientListeningController(
            notificationCenter: rig.center, requestPermission: { true },
            makeStreamer: { send in AmbientAudioStreamer(capture: rig.capture, send: send) },
            releaseSession: { rig.released += 1 },
            send: { audio, binding in
                try await store.sendAudio(audio, to: binding)
                // Model the sender continuation being descheduled after the store's successful return.
                if audio.isResume { try await delivery.sleep(.zero) }
            }
        )
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        for index in 0..<6 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await delivery.isWaiting() }
        let nonce = try await rig.waitForAcceptancePing()
        try await rig.socket.push(.pong(nonce: nonce))
        try await waitUntil { await MainActor.run { rig.controller.reconnect.acceptance == nil } }
        #expect(!rig.controller.reconnect.isPending) // Acceptance preceded transportSent on the sender executor.
        #expect(rig.notices.map(\.outcome) == [.applied])
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient busy elsewhere"))
        try await waitUntil { await MainActor.run { !rig.controller.isOn } }
        #expect(rig.notices.allSatisfy { $0.outcome != .failed },
                "A refusal after positive acceptance was still described as a dropped connection")
        #expect(rig.unexpected.count == 1,
                "A post-acceptance terminal refusal suppressed the ordinary stop alert")
        await delivery.fire()
        try await waitUntil { await MainActor.run { rig.released == 1 } }
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }

    @Test(arguments: [true, false])
    func acceptanceAndSendCompletionPublishOneNoticeAndHapticHook(acceptanceFirst: Bool) async throws {
        let run = try AmbientAcceptanceSettleRun()
        try await run.start()
        var hapticHooks = 0
        run.rig.controller.reconnect.onNotice = { [weak rig = run.rig] notice in
            rig?.notices.append(notice)
            hapticHooks += 1 // The app consumes onNotice as its notice/haptic hook.
        }
        try await run.settleFirst(acceptanceFirst: acceptanceFirst)
        #expect(!run.rig.controller.reconnect.isPending)
        #expect(await run.delivery.isWaiting() == acceptanceFirst)
        #expect((run.rig.controller.reconnect.acceptance == nil) == acceptanceFirst)
        #expect(run.rig.notices.map(\.outcome) == [.applied] && hapticHooks == 1)
        let id = run.rig.controller.reconnect.notice?.id
        try await run.completeSecond(acceptanceFirst: acceptanceFirst)
        #expect(run.rig.controller.isOn && run.rig.unexpected.isEmpty)
        #expect(run.rig.notices.map(\.id) == [id] && run.rig.notices.map(\.outcome) == [.applied])
        #expect(hapticHooks == 1)
        await run.rig.close()
    }
}
