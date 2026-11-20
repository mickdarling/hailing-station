import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyStopControlOrderTests {
    @Test(arguments: [false, true])
    func newerReplyFollowsStopOnWire(markQueued: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let session = rig.first.session
            _ = try await rig.startReply(on: rig.first)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = VoiceStopConfirmationHold(), completed = Mutex(false)
            defer { release.release() }
            let stopping = Task {
                await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                    entered.release(); await release.wait()
                }, operation: {
                    await rig.listener.stopReplyPlayback(connection: session.connectionID, markQueuedAudio: markQueued)
                })
            }
            await entered.wait()
            let context = try await rig.recipient.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            let text = recipientText(reply)
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
            #expect(!completed.withLock { $0 }, "Newer publication must await the accepted stop's control")
            release.release()
            #expect(await stopping.value == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            #expect(await publication.value == 1)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == text)
            let audio = recipientAudio(reply, sequence: 0)
            #expect(try await rig.listener.publish(audio) == 1)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == audio)
            #expect(await session.replyRequests[context.id] != nil)
        }
    }
}

private final class ReplyStopWireFlag: Sendable {
    private let value = Mutex(false)
    private let notification = VoiceStopConfirmationHold()
    func set() {
        value.withLock { $0 = true }
        notification.release()
    }
    func wait() async { await notification.wait() }
    var isSet: Bool { value.withLock { $0 } }
}

extension ReplyStopControlOrderTests {
    @Test func peerRetirementReleasesWaitingPublication() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            _ = try await rig.startReply(on: rig.first)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = ReplyStopWireFlag(), completed = ReplyStopWireFlag()
            defer { release.release() }
            let stopping = holdStop(rig, entered: entered, release: release)
            await entered.wait()
            let reply = recipientDescriptor(try await rig.recipient.submit(on: rig.first.session), audio: true)
            let publication = waitingFrame(rig, frame: recipientText(reply), waiting: waiting, completed: completed)
            await waiting.wait()
            #expect(!completed.isSet)
            await rig.first.peer.stop(reason: "synthetic retirement")
            await completed.wait()
            release.release()
            #expect(await publication.value == nil)
            _ = await stopping.value
        }
    }

    @Test func cancellingWaitingPublicationPreservesLaterRequest() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            _ = try await rig.startReply(on: rig.first)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = ReplyStopWireFlag(), completed = ReplyStopWireFlag()
            defer { release.release() }
            let stopping = holdStop(rig, entered: entered, release: release)
            await entered.wait()
            let context = try await rig.recipient.submit(on: rig.first.session)
            let reply = recipientDescriptor(context, audio: true)
            let publication = waitingFrame(rig, frame: recipientText(reply), waiting: waiting, completed: completed)
            await waiting.wait()
            #expect(!completed.isSet)
            publication.cancel()
            await completed.wait()
            release.release()
            #expect(await publication.value == nil)
            #expect(await stopping.value == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            #expect(await rig.first.session.replyRequests[context.id] != nil)
            let text = recipientText(reply)
            #expect(try await rig.listener.publish(text) == 1)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == text)
        }
    }

    private func holdStop(
        _ rig: ReplySegmentsRig, entered: VoiceStopConfirmationHold, release: VoiceStopConfirmationHold,
        markQueued: Bool = false
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

    private func waitingFrame(
        _ rig: ReplySegmentsRig, frame: Frame, waiting: ReplyStopWireFlag, completed: ReplyStopWireFlag
    ) -> Task<Int?, Never> {
        Task {
            await ReplyAudioEnqueueTesting.$waitingForControl.withValue({ waiting.set() }, operation: {
                let result = try? await rig.listener.publish(frame)
                completed.set()
                waiting.set()
                return result
            })
        }
    }
}

extension ReplyStopControlOrderTests {
    @Test(arguments: [false, true])
    func newerAudioOnlyReplyFollowsStopOnWire(markQueued: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            _ = try await rig.startReply(on: rig.first)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = ReplyStopWireFlag(), completed = ReplyStopWireFlag()
            defer { release.release() }
            let stopping = holdStop(rig, entered: entered, release: release, markQueued: markQueued)
            await entered.wait()
            let context = try await rig.recipient.submit(on: rig.first.session)
            let audio = recipientAudio(recipientDescriptor(context, audio: true), sequence: 0)
            let publication = waitingFrame(rig, frame: audio, waiting: waiting, completed: completed)
            await waiting.wait()
            #expect(!completed.isSet)
            release.release()
            #expect(await stopping.value == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            #expect(await publication.value == 1)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == audio)
            #expect(await rig.first.session.replyRequests[context.id] != nil)
        }
    }
}
