import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAuthOrderTests {
    @Test func waiterBeforeFailurePublicationKeepsAuthorizationRefusal() async throws {
        let run = try AmbientRefusalOrderRun()
        let selection = try await run.startSelection()
        try await run.refuse()
        await run.ping.fire()
        run.expectTerminalRefusal(await selection.result)
        #expect(run.rig.store.snapshots[run.rig.endpoint.id]?.state == .ready)
        try await run.settleStopIfRequested()
        try run.expectOwnerNotice()
        try await run.publishFailure()
        try run.expectOwnerNotice()
        try await run.expectNoPCMOrPrivacyOff()
        await run.rig.close()
    }

    @Test func failurePublicationBeforeWaiterKeepsAuthorizationRefusal() async throws {
        let run = try AmbientRefusalOrderRun()
        let selection = try await run.startSelection()
        try await run.refuse()
        try await run.publishFailure()
        try await run.settleStopIfRequested()
        try run.expectOwnerNotice()
        await run.ping.fire()
        run.expectTerminalRefusal(await selection.result)
        try run.expectOwnerNotice()
        try await run.expectNoPCMOrPrivacyOff()
        await run.rig.close()
    }

    @Test func transportOnlyCloseStillRetriesAfterTheHeldWaiter() async throws {
        let run = try AmbientRefusalOrderRun()
        let selection = try await run.startSelection()
        await run.rig.socket.fail()
        try await waitUntil { await run.closing.gate.isWaiting() }
        await run.ping.fire()
        if case .failure(let error) = await selection.result {
            #expect(error as? HostConnectionFailure == .notReady)
        } else { Issue.record("A transport loss must reject its selection") }
        #expect(run.rig.controller.reconnect.isPending && run.rig.controller.isListening)
        #expect(run.rig.notices.map(\.outcome) == [.interrupted])
        await run.closing.gate.fire()
        try await waitUntil { await run.rig.retry.isWaiting() }
        try await run.expectNoPCMOrPrivacyOff()
        try await run.rig.reconnect()
        #expect(run.rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(run.rig.controller.isListening && run.rig.capture.startCount == 1)
        await run.rig.close()
    }
}
