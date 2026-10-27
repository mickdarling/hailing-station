import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAcceptanceSettleTests {
    @Test(arguments: [true, false])
    func settlingNeverChangesPrivacyOrSendsPrivacy(acceptanceFirst: Bool) async throws {
        let run = try AmbientAcceptanceSettleRun()
        try await run.start()
        let privacy = run.rig.store.privacyLocal
        let duck = run.rig.store.duckMode
        #expect(duck[run.rig.endpoint.id]?.on == false)
        try await run.settleFirst(acceptanceFirst: acceptanceFirst)
        #expect(!run.rig.controller.reconnect.isPending)
        #expect(run.rig.store.privacyLocal == privacy && run.rig.store.duckMode == duck)
        try await run.completeSecond(acceptanceFirst: acceptanceFirst)
        #expect(run.rig.store.privacyLocal == privacy && run.rig.store.duckMode == duck)
        #expect(try await run.rig.socket.sentFrames().allSatisfy { frame in
            if case .control(.setPrivacy) = frame.payload { return false }
            return true
        })
        await run.rig.close()
    }
}

@MainActor
final class AmbientAcceptanceSettleRun {
    let rig: AmbientReconnectRig
    let delivery = SleepGate()
    private var nonce = ""

    init() throws {
        rig = try AmbientReconnectRig()
        let rig = rig
        let store = rig.store
        let delivery = delivery
        rig.controller = AmbientListeningController(
            notificationCenter: rig.center, requestPermission: { true },
            makeStreamer: { send in AmbientAudioStreamer(capture: rig.capture, send: send) },
            releaseSession: { rig.released += 1 },
            send: { audio, binding in
                try await store.sendAudio(audio, to: binding)
                if audio.isResume { try await delivery.sleep(.zero) }
            }
        )
    }

    func start() async throws {
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.socket.push(.duckMode(on: false, reason: "device"))
        try await waitUntil { await MainActor.run { self.rig.store.duckMode[self.rig.endpoint.id]?.on == false } }
        try await rig.select(restoring: true)
        for index in 0..<6 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await self.delivery.isWaiting() }
        nonce = try await rig.waitForAcceptancePing()
        #expect(rig.controller.reconnect.isPending && rig.notices.isEmpty)
    }

    func settleFirst(acceptanceFirst: Bool) async throws {
        if acceptanceFirst { try await accept() } else { try await completeSend() }
    }

    func completeSecond(acceptanceFirst: Bool) async throws {
        if acceptanceFirst { try await completeSend() } else { try await accept() }
    }

    private func accept() async throws {
        try await rig.socket.push(.pong(nonce: nonce))
        try await waitUntil { await MainActor.run { self.rig.controller.reconnect.acceptance == nil } }
    }

    private func completeSend() async throws {
        let count = try await audioFrames(rig.socket).count
        await delivery.fire()
        try await rig.feed()
        // A following frame proves transportSent ran and the held sender resumed its queue.
        try await waitUntil { try await audioFrames(self.rig.socket).count > count }
    }
}
