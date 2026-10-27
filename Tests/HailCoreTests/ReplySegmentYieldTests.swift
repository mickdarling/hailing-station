import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor @Suite struct ReplySegmentYieldTests {
    @Test func callableYieldStopsOnlyPausedReplyAndExposesDescriptorAndPlayedCount() {
        let rig = IdleRig(), reply = idleReply(), later = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.player.completeReply()
        rig.advance(by: .milliseconds(1_500))
        rig.controller.ingest(segmentAudio(reply, sequence: 1))
        rig.player.completeReply()
        rig.controller.ingest(idleAudio(reply, sequence: 2, final: true, byte: 3))
        rig.controller.ingest(idleAudio(later, sequence: 0, final: true, byte: 4))
        let yielded = rig.controller.yieldPausedReply(ambientListening: true, privacyOn: false)
        #expect(yielded?.endpointID == "main")
        #expect(yielded?.replyID == reply.id)
        #expect(yielded?.segment == 2)
        #expect(rig.controller.lastSegmentYield == yielded)
        #expect(rig.controller.segmentPause == nil)
        #expect(rig.player.cancelCount == 1)
        #expect(rig.player.scheduled.map(\.bytes.first) == [1, 2, 4])
        rig.controller.ingest(idleAudio(reply, sequence: 3, final: true, byte: 5))
        rig.advance(by: .seconds(40))
        #expect(rig.player.scheduled.count == 3)
        #expect(rig.controller.activeKey?.replyID == later.id)
        #expect(rig.controller.yieldPausedReply(ambientListening: true, privacyOn: false) == nil)
    }

    @Test(arguments: [(false, false), (false, true), (true, true)])
    func privacyAndAmbientOffRefuseCallableYield(ambient: Bool, privacy: Bool) {
        let rig = IdleRig(), reply = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.player.completeReply()
        #expect(rig.controller.yieldPausedReply(ambientListening: ambient, privacyOn: privacy) == nil)
        #expect(rig.controller.lastSegmentYield == nil)
        #expect(rig.player.cancelCount == 0)
        #expect(rig.controller.segmentPause != nil)
        rig.advance(by: .milliseconds(1_500))
        #expect(rig.controller.segmentPause == nil) // Privacy never removes the planned pause.
    }

    @Test func callableYieldOutsidePlayedWindowDoesNothing() {
        let rig = IdleRig(), reply = idleReply()
        #expect(rig.controller.yieldPausedReply(ambientListening: true, privacyOn: false) == nil)
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        #expect(rig.controller.yieldPausedReply(ambientListening: true, privacyOn: false) == nil)
        rig.player.completeReply()
        rig.advance(by: .milliseconds(1_500))
        #expect(rig.controller.yieldPausedReply(ambientListening: true, privacyOn: false) == nil)
        #expect(rig.player.cancelCount == 0)
    }

    @Test func engineDiscardRetiresBarrierWithoutOpeningWindow() async throws {
        let rig = IdleRig(), reply = idleReply(), later = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.controller.ingest(idleAudio(later, sequence: 0, final: true, byte: 4))
        rig.player.onSegmentDiscarded?()
        try await waitUntil { @MainActor in rig.controller.activeKey?.replyID == later.id }
        #expect(rig.controller.segmentPause == nil)
        #expect(rig.controller.lastSegmentYield == nil)
        #expect(rig.player.cancelCount == 1)
        #expect(rig.controller.segmentBoundary == nil)
        rig.player.completeReply() // Flushed completion cannot open an old window.
        #expect(rig.controller.segmentPause == nil)
    }

    @Test func staleCompletionCannotPauseAReplacementReply() {
        let rig = IdleRig(), reply = idleReply(), later = idleReply()
        rig.controller.ingest(segmentAudio(reply, sequence: 0))
        rig.controller.stopPlayback(from: "main")
        rig.controller.ingest(segmentAudio(later, sequence: 0))
        rig.player.completeReply() // Old player's cancellation completion.
        #expect(rig.controller.segmentPause == nil)
        rig.player.completeReply()
        #expect(rig.controller.segmentPause?.replyID == later.id)
        #expect(rig.controller.segmentPause?.segment == 1)
    }
}
