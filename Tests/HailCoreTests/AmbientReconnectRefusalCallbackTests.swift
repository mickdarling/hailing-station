import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #1037: force callbacks into the interval before the refusal's asynchronous teardown runs.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientReconnectRefusalCallbackTests {
    @Test(arguments: [false, true])
    func refusalRetiresListeningBeforeLateFailureCanArmAnotherRestore(transport: Bool) async throws {
        try await withAmbientRefusalRig { rig, steps in
            try await self.checkCallback(rig, steps: steps, transport: transport)
        }
    }

    private func checkCallback(_ rig: AmbientReconnectRig, steps: AmbientRefusalSteps, transport: Bool) async throws {
        let clock: TestInstantClock = TestInstantClock()
        let gate: AmbientRefusalSteps = AmbientRefusalSteps()
        defer { gate.releaseAll() }
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { @MainActor in steps.started == 1 }
        try await rig.restoreForRefusal(steps: steps, retryIndex: 0)
        try await rig.waitForAcceptancePing()
        let proof: AmbientResumeAcceptance = try #require(rig.controller.reconnect.acceptance)
        let noticeID: UUID = try #require(rig.controller.reconnect.notice?.id)
        let audio: AudioPayload = ambientSegment(stream: proof.streamID)
        let callback: Task<Void, any Error> = Task { @MainActor in
            try await gate.sleep(.zero)
            // The receive loop delivers this callback without requiring another microphone buffer.
            rig.controller.receiveAmbientRefusal(
                HostConnectionFailure.remote("not_allowed: ambient moved to pad"), host: proof.binding.hostID,
                generation: proof.binding.connectionGeneration, streamID: proof.streamID
            )
            // Run the delayed callback before yielding to the Task that ends the listening session.
            let error: any Error = transport ? SocketTestError.closed : HostConnectionFailure.notReady
            rig.controller.reconnect.sendFailed(error, audio: audio, binding: proof.binding, store: rig.store)
            #expect(!rig.controller.isListening && !rig.controller.reconnect.isPending)
            #expect(rig.controller.reconnect.replacedAppliedNotice)
        }
        defer { callback.cancel() }
        try await waitUntil { @MainActor in gate.started == 1 }
        clock.advance(by: .seconds(5))
        gate.release(0)
        try await ambientRefusalDeadline { try await callback.value }
        try await rig.expectSingleRefusal(noticeID)
    }
}

extension AmbientReconnectRig {
    func expectSingleRefusal(_ noticeID: UUID) async throws {
        try await waitUntil { @MainActor in !self.controller.isOn && self.released == 1 }
        let ids: [UUID] = notices.map(\.id)
        let uniqueIDs: Set<UUID> = Set(ids)
        #expect(ids == [noticeID, noticeID])
        #expect(uniqueIDs.count == 1) // The app haptics once per distinct notice ID.
        #expect(controller.reconnect.notice?.id == noticeID)
        #expect(controller.reconnect.replacedAppliedNotice)
        #expect(notices.last?.outcome == .failed && notices.last?.reason == .movedAway)
        #expect(controller.handoff == .movedAway(to: "pad") && unexpected.isEmpty)
        #expect(capture.startCount == 1 && !controller.reconnect.isPending)
    }
}
