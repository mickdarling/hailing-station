import Foundation
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectResetTests {
    @Test func successfulRestoreResetsTheNextDropToFastRetry() async throws {
        let run = try AmbientBackoffRun()
        try await run.rig.start()
        try await run.failSeveralAttempts()
        let rig = run.rig
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await run.steps.release(3)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await rig.feed()
        #expect(rig.notices.last?.outcome == .applied)
        await rig.socket.fail()
        try await waitUntil { await run.steps.started == 5 }
        #expect(await run.steps.durations.last == .seconds(1.5))
        #expect(rig.controller.reconnect.status == "Reconnecting…")
        await run.close()
    }

    @Test func privateHandshakeAndUnconfirmedRestoreDoNotResetTheBackoff() async throws {
        let run = try AmbientBackoffRun()
        let rig = run.rig
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        try await run.failSeveralAttempts()
        rig.socket = ScriptedSocket()
        let host = AmbientPrivacyHost(base: rig.socket)
        await rig.connector.enqueue(.socket(host), for: rig.endpoint.url)
        await run.steps.release(3)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await waitUntil { await host.receivedRequest() }
        #expect(rig.controller.reconnect.status == "Reconnecting…")
        try await rig.expectNoRestoredPCM()
        await rig.socket.fail()
        try await waitUntil { await run.steps.started == 5 }
        #expect(await run.steps.durations.last == .seconds(24))
        #expect(rig.notices.map(\.outcome) == [.interrupted])
        #expect(rig.capture.startCount == 1 && rig.controller.isOn)
        await run.close()
    }

    @Test func refusalBackstopStartsAtRestoreEvenAfterAnHourOffline() async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.drop()
        clock.advance(by: .seconds(3_600))
        try await rig.reconnect()
        try await rig.waitForAcceptancePing()
        let notice = rig.controller.reconnect.notice?.id
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient busy"))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.map(\.id) == [notice, notice])
        #expect(rig.notices.last?.outcome == .failed && rig.unexpected.isEmpty)
        await rig.close()
    }

    @Test func backgroundMicRetryKeepsTheVisibleReasonUntilForeground() async throws {
        let harness = InterruptionPauseHarness()
        let controller = harness.controller
        let current = try binding()
        await controller.turnOn(for: current)
        harness.interruption(began: true)
        try await harness.waitForBackoff()
        await controller.update(binding: current, scene: .background)
        await harness.steps.release()
        try await harness.waitForBackoff()
        harness.interruption(began: false)
        await settle()
        #expect(controller.isOn && !controller.isListening && harness.fakes.count == 1)
        #expect(controller.pausedReason == AmbientListeningController.foregroundPausedStatus)
        await controller.update(binding: current, scene: .active)
        #expect(controller.isListening && harness.fakes.count == 2)
        #expect(controller.pausedReason == nil)
        await controller.turnOff()
        await harness.steps.release()
    }
}

@MainActor
private final class AmbientBackoffRun {
    let steps = AmbientRetrySteps()
    let rig: AmbientReconnectRig

    init() throws {
        let steps = steps
        rig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) })
    }

    func failSeveralAttempts() async throws {
        await rig.socket.fail()
        for index in 0..<3 {
            try await waitUntil { await self.steps.started == index + 1 }
            await steps.release(index)
        }
        try await waitUntil { await self.steps.started == 4 }
        #expect(await steps.durations.last == .seconds(12))
    }

    func close() async {
        await rig.close()
        await steps.releaseAll()
    }
}

/// #904: a previous host's cancelled pacing must not poison its ordinary transport retries.
@MainActor
@Suite(.serialized) struct AmbientReconnectOwnerRegressionTests {
    @Test func startingOnAnotherHostAfterRecoveryLeavesTheOldHostAbleToReconnect() async throws {
        let steps = AmbientRetrySteps()
        let rig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) })
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await steps.started == 1 }
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await steps.release(0)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await rig.feed()
        #expect(rig.notices.last?.outcome == .applied)
        let pacing = try #require(rig.controller.reconnect.pacing)
        await rig.controller.turnOff()
        #expect(!pacing.isCancelled) // The next owner start, rather than an active recovery veto, revokes it.
        let other = AmbientAudioBinding(hostID: "second-synthetic-host", targetID: rig.target.id,
                                        connectionGeneration: UUID(), selection: 0)
        await rig.controller.turnOn(for: other)
        #expect(pacing.isCancelled && rig.controller.reconnect.pacing == nil)
        await rig.socket.fail()
        try await waitUntil {
            if await steps.started == 2 { return true }
            return await MainActor.run { rig.store.snapshots[rig.endpoint.id]?.state == .disconnected }
        }
        try #require(await steps.started == 2)
        #expect(await steps.durations.last == .seconds(1)) // Ordinary transport pacing, not the old ambient owner.
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await steps.release(1)
        try await rig.handshake(rig.socket)
        #expect(rig.controller.isOn && rig.controller.isListening && rig.controller.binding == other)
        await rig.close()
        await steps.releaseAll()
    }

    @Test(arguments: ["path", "foreground"])
    func aNudgeDiscardsCancelledPacingWhenTheProviderReturnsNil(_ trigger: String) async throws {
        let source = AmbientPacingSource()
        let pacing = try #require(source.pacing)
        let steps = AmbientRetrySteps()
        let connection = HostConnection(endpoint: try endpoint(), connector: ScriptedConnector(),
                                        deadlineSleep: { _ in throw CancellationError() },
                                        sleep: { try await steps.sleep($0) }, jitter: { 0.5 })
        await connection.setReconnectPacing { await source.pacing }
        await connection.connect()
        try await waitUntil { await steps.started == 1 }
        #expect(await connection.ambientPacing === pacing)
        pacing.cancel()
        source.pacing = nil
        if trigger == "path" { await connection.networkPathChanged() } else { await connection.foregrounded() }
        #expect(await connection.ambientPacing == nil)
        try await waitUntil { await steps.started == 2 }
        #expect(await steps.durations.last == .seconds(1))
        await connection.disconnect()
        await steps.releaseAll()
    }
}

@MainActor
private final class AmbientPacingSource {
    var pacing: AmbientReconnectPacing? = AmbientReconnectPacing()
}
