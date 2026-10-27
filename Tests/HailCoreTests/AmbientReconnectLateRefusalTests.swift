import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectLateRefusalTests {
    // P1: a final host refusal long after a successful restore, on the restored stream that has been healthy.
    // Expectation: it is an ordinary stop (a calm #366 handoff, or the normal unexpected-stop alert), not a rewrite
    // of the restore's "reconnected" notice into "Connection dropped; listening stopped".
    @Test(arguments: [true, false])
    func refusalLongAfterAppliedRestoreUsesOrdinaryStopPath(movedAway: Bool) async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.applied])
        for _ in 0..<3 { try await rig.feed() }
        clock.advance(by: .seconds(3_600))
        let message = movedAway ? "ambient moved to pad" : "ambient busy elsewhere"
        try await rig.socket.push(.error(code: .notAllowed, message: message))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.count == 1, "An hour-later refusal rewrote the restore notice into a connection-drop stop")
        if !movedAway { #expect(rig.unexpected.count == 1, "The ordinary stop alert was suppressed") }
        #expect(!rig.controller.reconnect.replacedAppliedNotice)
        if movedAway {
            #expect(rig.controller.handoff == .movedAway(to: "pad") && rig.unexpected.isEmpty)
        } else {
            #expect(rig.unexpected.first?.contains(message) == true)
        }
        await rig.close()
    }

    // P1 control: the same refusal in a run with no restore produces no reconnect notice.
    @Test func refusalWithoutRestoreUsesOrdinaryStopPath() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.feed()
        try await waitUntil { try await audioFrames(rig.socket).isEmpty == false }
        #expect(!rig.controller.reconnect.isPending && rig.notices.isEmpty)
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient busy elsewhere"))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.isEmpty && rig.unexpected.count == 1)
        await rig.close()
    }
}
