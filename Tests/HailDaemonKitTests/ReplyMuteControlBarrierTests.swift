import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyMuteControlBarrierTests {
    @Test func muteBarrierPreservesEarlierRequestAndOrdersStopBeforeItsAnswer() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let context = try await rig.recipient.submit(on: rig.first.session)
            let other = recipientDescriptor(try await rig.recipient.submit(on: rig.second.session), audio: true)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = VoiceStopConfirmationHold(), completed = Mutex(false)
            defer { release.release() }
            let muting = Task {
                await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                    entered.release(); await release.wait()
                }, operation: {
                    await rig.listener.stopReplyPlayback(connection: rig.first.session.connectionID,
                        markQueuedAudio: false, preservingRequests: true)
                })
            }
            await entered.wait()
            let reply = recipientDescriptor(context, audio: true), text = recipientText(reply)
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
            #expect(!completed.withLock { $0 }, "Mute orders the stop without revoking the earlier request")
            let otherText = recipientText(other)
            #expect(try await rig.listener.publish(otherText) == 1)
            #expect(try await recipientSocketReceive(on: rig.second.socket) == otherText)
            release.release()
            #expect(await muting.value == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            #expect(await publication.value == 1)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == text)
            #expect(await rig.first.session.replyRequests[context.id] != nil)
        }
    }
}
