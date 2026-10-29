import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectSendRefusalTests {
    @Test(arguments: RefusalPingSendError.allCases)
    func sendErrorBeforeFailurePublicationKeepsAuthorizationRefusal(error: RefusalPingSendError) async throws {
        let run = try AmbientRefusalOrderRun()
        let selection = try await run.startSelection(sendError: error)
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

    @Test(arguments: RefusalPingSendError.allCases)
    func failurePublicationBeforeSendErrorKeepsAuthorizationRefusal(error: RefusalPingSendError) async throws {
        let run = try AmbientRefusalOrderRun()
        let selection = try await run.startSelection(sendError: error)
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

    @Test(arguments: RefusalPingSendError.allCases)
    func ownerStopAndCancelledWaiterKeepCancellation(error: RefusalPingSendError) async throws {
        let run = try AmbientRefusalOrderRun()
        let selection = try await run.startSelection(sendError: error)
        try await run.refuse()
        await run.rig.controller.turnOff()
        selection.cancel()
        await run.ping.fire()
        if case .failure(let failure) = await selection.result {
            #expect(failure is CancellationError)
        } else { Issue.record("The cancelled owner selection must fail") }
        let notices = run.rig.notices
        try await run.publishFailure()
        #expect(run.rig.notices == notices)
        #expect(!run.rig.controller.isOn && !run.rig.controller.isListening)
        try await run.expectNoPCMOrPrivacyOff()
        await run.rig.close()
    }

    @Test func cancelledPongWaiterKeepsCancellationAfterRefusal() async throws {
        let run = try AmbientRefusalOrderRun()
        let selection = try await run.startSelection()
        try await run.refuse()
        selection.cancel()
        await run.ping.fire()
        if case .failure(let failure) = await selection.result {
            #expect(failure is CancellationError)
        } else { Issue.record("A cancelled pong waiter must fail") }
        try await run.publishFailure()
        await run.rig.close()
    }
}
