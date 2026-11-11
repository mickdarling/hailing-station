#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioPrivacyBarrierTests {
    @Test(arguments: [false, true])
    func devicePrivacyEntryHoldsFirstFrameAcrossTeardown(teardown: Bool) async throws {
        let rig = try await DuckRig(script: AmbientPrivacyConfirmAfterAckTests.heldSwitch(),
            capabilities: [DuckMode.capability, PlaybackStop.capability])
        let snapshot = VoiceStopConfirmationHold(), timeout = VoiceStopConfirmationHold()
        defer { rig.close(); snapshot.release(); timeout.release() }
        do {
            try #require(await eventually { rig.details("ambient_duck_confirmed").count == 1 })
            try await exercise(rig, teardown: teardown, snapshot: snapshot, timeout: timeout)
        } catch {
            snapshot.release(); timeout.release()
            AmbientPrivacyAckGateTests.go(rig.fake)
            await rig.finish()
            throw error
        }
        AmbientPrivacyAckGateTests.go(rig.fake)
        await rig.finish()
    }

    private func exercise(
        _ rig: DuckRig, teardown: Bool, snapshot: VoiceStopConfirmationHold, timeout: VoiceStopConfirmationHold
    ) async throws {
        let listener = rig.env.listener, connection = try #require(rig.connection())
        let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
            selecting: [RecipientTestRig.target])
        defer { other.close() }
        _ = try await other.submitInput(on: 0, rig: rig.env.rig)
        let frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
        let old = try #require(await listener.replyAudio(.init(action: "enqueue", frame: frame)).ticket)
        let entered = VoiceStopConfirmationHold(), waiting = VoiceStopConfirmationHold()
        ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            ReplyAudioEnqueueTesting.$beforeStopSnapshot.withValue({
                entered.release(); await snapshot.wait()
            }, operation: { rig.env.router.ambientPrivacy(true, connection: connection) })
        })
        await entered.wait()
        let publication = Task {
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await listener.replyAudio(.init(action: "publish", ticket: old, frame: frame))
            })
        }
        await waiting.wait()
        if teardown { await removePeer(connection, on: listener) }
        try await publishLater(frame, listener: listener, socket: other.sockets[0])
        snapshot.release()
        #expect(try await publication.value == LocalReplyAudioReport(skipped: true))
        try await other.boundedBarrier(step: "privacy entry silences B's old ticket only")
    }

    private func removePeer(_ connection: UUID, on listener: WebSocketListener) async {
        for (id, peer) in await listener.peers where await peer.session.connectionID == connection {
            await listener.peerEnded(id)
        }
    }

    private func publishLater(
        _ frame: Frame, listener: WebSocketListener, socket: URLSessionWebSocketTask
    ) async throws {
        let later = try #require(await listener.replyAudio(.init(action: "enqueue", frame: frame)).ticket)
        #expect(try await listener.replyAudio(.init(action: "publish", ticket: later, frame: frame))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: socket, step: "post-privacy ticket plays during pending snapshot") == frame)
    }
}
#endif
