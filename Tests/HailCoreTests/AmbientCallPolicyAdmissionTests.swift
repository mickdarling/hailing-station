import Foundation
import Testing
@testable import HailCore
@testable import HailDaemonKit

@MainActor
@Suite(.serialized) struct AmbientCallPolicyAdmissionTests {
    @Test func unannouncedPolicyWriteAdmitsOneSegmentThenStopsOnRefusal() async throws {
        try await refusedAdmission(denyBeforePause: false)
    }

    @Test func retainedDenyAdmitsOneSegmentThenStopsOnRefusal() async throws {
        try await refusedAdmission(denyBeforePause: true)
    }

    private func refusedAdmission(denyBeforePause: Bool) async throws {
        let rig = try CallReconnectRig()
        let host = try await CallPolicyHost.make(base: rig.socket, target: rig.target.id)
        rig.transport = host
        try await rig.start()
        if !denyBeforePause {
            try await rig.feed()
            try await callEventually { host.sink.segmentCount > 0 }
        }
        if denyBeforePause {
            _ = try await host.host.deny(rig.target.id)
        }
        try await rig.interrupt()
        if !denyBeforePause {
            _ = try await host.host.deny(rig.target.id)
        }
        let admitted = host.sink.segmentCount
        let before = try await audioFrames(rig.socket).count
        #expect(await host.refusals == 0)
        rig.interruptionEnded()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        try rig.capture.yield(sineBuffer(frames: 19_200))
        try await finishCallPolicyRefusal(rig, gate: host.sendGate, before: before)
        let attempts = await host.resumedAttempts
        let refusals = await host.refusals
        #expect(attempts == 1 && refusals == 1)
        #expect(host.sink.segmentCount == admitted)
        await rig.close()
    }
}
