#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #941 with #932: on a restored-private connection, the agent's reply segments are held like any reply, and the
/// device's `reply_yield` only ever stops a reply: it releases nothing held. Synthetic only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkReplyYieldTests {
    @Test func aYieldOnAHeldReplyReleasesNothing() async throws {
        let rig = try await AmbientPrivacyParkTests.privacyDropped()
        defer { rig.close() }
        let (socket, connection) = try await rig.start(capabilities: ["probe", ReplySegments.capability])
        #expect(await rig.env.listener.replyHold.holds(connection))
        let descriptor = AmbientPrivacyReplyTests.descriptor(audio: true)
        var segment = AmbientPrivacyReplyTests.reply(descriptor, sequence: 0)
        if case .audio(var audio) = segment.payload {
            audio.isSegmentEnd = true
            segment.payload = .audio(audio)
        }
        #expect(await AmbientPrivacyParkHoldTests.publish(segment, on: rig) == .privacyHeld)
        try await recipientSocketSend(sessionFrame(payload: .control(.replyYield(reply: descriptor.id, segment: 1))),
                                      on: socket)
        try await barrier(on: socket, step: "nothing released by the yield")
        let later = AmbientPrivacyReplyTests.reply(descriptor, sequence: 1, final: true)
        // Refused while held, it was stopped (#735 S-2c), so its later frames are refused as stopped; and the hold is
        // still on, so a new reply is held.
        #expect(await AmbientPrivacyParkHoldTests.publish(later, on: rig) == .replyStopped, "the reply stays stopped")
        let fresh = AmbientPrivacyReplyTests.reply(AmbientPrivacyReplyTests.descriptor(), text: "synthetic answer")
        #expect(await AmbientPrivacyParkHoldTests.publish(fresh, on: rig) == .privacyHeld, "the hold is still on")
        try await barrier(on: socket, step: "nothing of the reply after the yield")
        await rig.finish()
    }
}
#endif
