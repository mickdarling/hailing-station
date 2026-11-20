import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReviewRound6RequestlessOrderProbes {
    @Test(arguments: [false, true])
    func newerRequestlessReplyMustFollowAcceptedStop(markQueued: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            _ = try await rig.startReply(on: rig.first)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let completed = Mutex(false), waiting = VoiceStopConfirmationHold()
            defer { release.release() }
            let stopping = heldStop(rig, entered: entered, release: release, markQueued: markQueued)
            await entered.wait()
            let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                        audioStreamID: UUID())
            let text = recipientText(reply)
            let probe = recipientAudio(reply, sequence: 0)
            let ticket = try #require(await rig.listener.replyAudio(.init(action: "enqueue", frame: probe)).ticket)
            let publication = Task {
                await ReplyAudioEnqueueTesting.$waitingForControl.withValue(
                    { waiting.release() }, operation: {
                    let delivered = try? await rig.listener.publish(text)
                    completed.withLock { $0 = true }
                    waiting.release()
                    return delivered
                })
            }
            await waiting.wait()
            #expect(!completed.withLock { $0 }, "Newer requestless text must await the accepted stop")
            release.release()
            #expect(await stopping.value == "stopped")
            #expect(await publication.value == 1)
            let first = try await recipientSocketReceive(on: rig.first.socket)
            let second = try await recipientSocketReceive(on: rig.first.socket)
            #expect(first.payload == .control(.stopPlayback))
            #expect(second == text)
            let audio = try await rig.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: probe))
            #expect(!audio.skipped)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == probe)
        }
    }

    private func heldStop(
        _ rig: ReplySegmentsRig, entered: VoiceStopConfirmationHold,
        release: VoiceStopConfirmationHold, markQueued: Bool
    ) -> Task<String, Never> {
        Task {
            await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                entered.release(); await release.wait()
            }, operation: {
                await rig.listener.stopReplyPlayback(
                    connection: rig.first.session.connectionID, markQueuedAudio: markQueued
                )
            })
        }
    }
}
