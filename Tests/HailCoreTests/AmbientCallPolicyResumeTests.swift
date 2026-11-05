import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientCallPolicyResumeTests {
    @Test func firstResumedSegmentPolicyRefusalStopsWithoutRetry() async throws {
        let rig = try CallReconnectRig()
        let host = CallPolicyRefusingSocket(base: rig.socket)
        rig.transport = host
        try await rig.start()
        try await rig.feed()
        try await callEventually { try await !audioFrames(rig.socket).isEmpty }
        try await rig.interrupt()
        let before = try await audioFrames(rig.socket).count
        rig.interruptionEnded()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        // The held first send lets the refusal discard every queued segment deterministically.
        try rig.capture.yield(sineBuffer(frames: 19_200))
        try await finishCallPolicyRefusal(rig, gate: host.sendGate, before: before)
        #expect(await host.resumedAttempts == 1)
        await rig.close()
    }
}
