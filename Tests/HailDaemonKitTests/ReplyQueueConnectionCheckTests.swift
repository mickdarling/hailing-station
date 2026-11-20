import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyQueueConnectionCheckTests {
    @Test func otherConnectionQueueSkipMustNotRetractBoundRequest() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.second.session
            let context = try await rig.recipient.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            let probe = recipientAudio(reply, sequence: 0)
            let ticket = try #require(await rig.listener.replyAudio(.init(action: "enqueue", frame: probe)).ticket)
            #expect(try await rig.listener.publish(recipientText(reply)) == 1)
            _ = try await recipientSocketReceive(on: rig.second.socket)
            #expect(await rig.listener.stopReplyPlayback(connection: rig.first.session.connectionID,
                                                         markQueuedAudio: true) == "stopped")
            _ = try await recipientSocketReceive(on: rig.first.socket)
            let checked = try await rig.listener.replyAudio(.init(action: "check", ticket: ticket, frame: probe))
            #expect(!checked.skipped && checked.reason == nil)
            let beforeRenewal = await session.replyPublicationStatus(probe)
            rig.recipient.clock.advance(20_000)
            _ = await session.renewQueuedReplyAuthority()
            let preserved = await session.replyRequests[context.id] != nil
            let delivered = try? await rig.listener.publish(probe)
            if delivered == 1 { _ = try await recipientSocketReceive(on: rig.second.socket) }
            #expect(beforeRenewal == .ready)
            #expect(preserved)
            #expect(delivered == 1)
        }
    }
}

extension ReplyQueueConnectionCheckTests {
    @Test func pendingOtherConnectionStopDoesNotConsumeTheCheckBudget() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.second.session
            let context = try await rig.recipient.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            let probe = recipientAudio(reply, sequence: 0)
            let ticket = try #require(await rig.listener.replyAudio(.init(action: "enqueue", frame: probe)).ticket)
            #expect(try await rig.listener.publish(recipientText(reply)) == 1)
            _ = try await recipientSocketReceive(on: rig.second.socket)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let timeout = VoiceStopConfirmationHold(), completed = Mutex(false)
            defer { release.release(); timeout.release() }
            let stopping = Task {
                await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                    await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                        entered.release(); await release.wait()
                    }, operation: {
                        await rig.listener.stopReplyPlayback(connection: rig.first.session.connectionID,
                                                             markQueuedAudio: true)
                    })
                })
            }
            await entered.wait()
            let checking = Task {
                let result = try? await rig.listener.replyAudio(.init(action: "check", ticket: ticket, frame: probe))
                completed.withLock { $0 = true }
                return result
            }
            #expect(await eventually { completed.withLock { $0 } })
            release.release()
            #expect(await stopping.value == "stopped")
            _ = try await recipientSocketReceive(on: rig.first.socket)
            #expect(await checking.value == LocalReplyAudioReport())
            #expect(await session.replyPublicationStatus(probe) == .ready)
        }
    }
}
