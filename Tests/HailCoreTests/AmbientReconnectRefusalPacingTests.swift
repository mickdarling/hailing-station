import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #1037: obsolete pacing completions and ordinary retries must not manufacture another drop.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientReconnectRefusalPacingTests {
    @Test(arguments: ["retry", "path", "foreground"])
    func delayedRetryCompletionCannotReplaceTheAppliedNotice(_ ordering: String) async throws {
        try await withAmbientRefusalRig { rig, steps in
            try await self.checkRefusal(rig, steps: steps, ordering: ordering)
        }
    }

    private func checkRefusal(_ rig: AmbientReconnectRig, steps: AmbientRefusalSteps, ordering: String) async throws {
        let clock: TestInstantClock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { @MainActor in steps.started == 1 }
        switch ordering {
        case "path": await rig.store.networkPathChanged()
        case "foreground": await rig.store.sceneBecameActive()
        default: steps.release(0) // One ordinary failed open before the successful retry.
        }
        try await waitUntil { @MainActor in steps.started == 2 }
        try await rig.restoreForRefusal(steps: steps, retryIndex: 1)
        let noticeID: UUID = try #require(rig.controller.reconnect.notice?.id)
        try await rig.waitForAcceptancePing()
        let proof: AmbientResumeAcceptance = try #require(rig.controller.reconnect.acceptance)
        clock.advance(by: .seconds(5))
        // No suspension between refusal and the late failure: teardown cannot win this race by scheduling luck.
        rig.controller.receiveAmbientRefusal(
            HostConnectionFailure.remote("not_allowed: ambient moved to pad"), host: proof.binding.hostID,
            generation: proof.binding.connectionGeneration, streamID: proof.streamID
        )
        rig.controller.reconnect.sendFailed(
            HostConnectionFailure.notReady, audio: ambientSegment(stream: proof.streamID),
            binding: proof.binding, store: rig.store
        )
        #expect(!rig.controller.isListening && !rig.controller.reconnect.isPending)
        steps.release(0) // A cancelled sleeper deliberately returns success after refusal.
        try await waitUntil { @MainActor in steps.completed == 2 }
        await rig.store.networkPathChanged() // A reset on the ready socket must leave it ready.
        #expect(steps.started == 2)
        #expect(!rig.controller.reconnect.isPending && rig.controller.reconnect.pacing == nil)
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
        let opens: Int = await rig.connector.openCount(for: rig.endpoint.url)
        #expect(opens == (ordering == "retry" ? 3 : 2))
        try await rig.expectSingleRefusal(noticeID)
    }
}
