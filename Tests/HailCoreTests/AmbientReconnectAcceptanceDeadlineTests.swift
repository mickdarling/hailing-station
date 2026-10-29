import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAcceptanceDeadlineTests {
    @Test func acceptanceAfterALongOutageCompletesRecovery() async throws {
        let run = try AmbientAcceptanceSettleRun()
        let clock = TestInstantClock()
        run.rig.controller.reconnect.now = { clock.now() }
        let rig = run.rig
        try await rig.start()
        try await rig.drop()
        clock.advance(by: .seconds(3_600))
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        for index in 0..<6 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await run.delivery.isWaiting() }
        let nonce = try await rig.waitForAcceptancePing()
        #expect(rig.controller.reconnect.isPending && rig.notices.isEmpty)
        clock.advance(by: .seconds(1))
        try await rig.socket.push(.pong(nonce: nonce))
        try await waitUntil { await MainActor.run { rig.controller.reconnect.acceptance == nil } }
        await run.delivery.fire()
        for index in 0..<6 { try run.rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await MainActor.run { !run.rig.controller.reconnect.isPending } }
        #expect(run.rig.notices.map(\.outcome) == [.applied])
        #expect(run.rig.controller.isListening && run.rig.capture.startCount == 1)
        await run.rig.close()
    }
}
