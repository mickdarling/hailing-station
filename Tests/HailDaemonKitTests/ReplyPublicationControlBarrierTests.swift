import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Real loopback wire checks of every reply publication boundary; invented content and PCM only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyPublicationControlBarrierTests {
    enum Kind: CaseIterable, Sendable {
        case routed, clip, acknowledgement, confirmation, sessionCard, taskProgress, proactiveAudio
    }

    @Test(arguments: Kind.allCases, [false, true])
    func stopPrecedesFirstFrame(kind: Kind, marked: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let old = try await startRequestless(rig)
            let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
            let waiting = VoiceStopConfirmationHold(), completed = Mutex(false)
            defer { release.release() }
            let stopping = Task {
                await ReplyAudioEnqueueTesting.$beforeStopSession.withValue({
                    entered.release(); await release.wait()
                }, operation: {
                    await rig.listener.stopReplyPlayback(
                        connection: rig.first.session.connectionID, markQueuedAudio: marked)
                })
            }
            await entered.wait()
            let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                        audioStreamID: UUID())
            let frames = frames(kind, reply: reply)
            let publishing = Task {
                await ReplyAudioEnqueueTesting.$waitingForControl.withValue(
                    { waiting.release() }, operation: {
                    let result = await publish(kind, frames: frames, rig: rig)
                    completed.withLock { $0 = true }
                    waiting.release()
                    return result
                })
            }
            await waiting.wait()
            #expect(!completed.withLock { $0 })
            release.release()
            #expect(await stopping.value == "stopped")
            #expect(await publishing.value)
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            for expected in frames { #expect(try await recipientSocketReceive(on: rig.first.socket) == expected) }
            // The barrier must not restore a stopped stream's authority.
            #expect(await rig.first.peer.deliverRequestlessReply(recipientAudio(old, sequence: 1)).succeeded == false)
        }
    }

    private func frames(_ kind: Kind, reply: ReplyDescriptor) -> [Frame] {
        switch kind {
        case .sessionCard, .taskProgress:
            return [sessionFrame(payload: .control(.sessionUpdate(update: reply.id, session: "reply",
                priority: "action", text: "Synthetic progress", card: "Synthetic detail")))]
        case .proactiveAudio:
            var proactive = reply
            proactive.sessionUpdateID = reply.id
            proactive.priority = .background
            return [recipientAudio(proactive, sequence: 0, final: true)]
        case .clip, .acknowledgement, .confirmation:
            return [recipientText(reply), recipientAudio(reply, sequence: 0, final: true)]
        default: return [recipientText(reply)]
        }
    }

    private func publish(_ kind: Kind, frames: [Frame], rig: ReplySegmentsRig) async -> Bool {
        let peer = rig.first.peer
        switch kind {
        case .routed: return await peer.deliverRoutedReply(frames[0]).succeeded
        case .acknowledgement:
            for frame in frames {
                guard await peer.deliverRequestlessReply(frame).succeeded else { return false }
            }
            return true
        case .clip:
            let results = await peer.deliverRequestlessClip(frames, hold: PrivateReplyHold(),
                                                           onLateSuccess: frames.map { _ in {} })
            return results.count == frames.count && results.allSatisfy(\.succeeded)
        case .confirmation:
            return await confirm(frames, peer: peer, connection: rig.first.session.connectionID)
        case .sessionCard, .taskProgress, .proactiveAudio:
            // These dedicated policy paths share prepared publication, not generic reply routing.
            guard let prepared = await peer.prepareReplyPublication(frames[0]), prepared.enqueue() else { return false }
            return await prepared.result() == .sent
        }
    }

    private func confirm(_ frames: [Frame], peer: WebSocketPeer, connection: UUID) async -> Bool {
        // Same atomic final boundary as confirmAmbientStop, with its independent admit gate open.
        var prepared: [PreparedWebSocketReply] = []
        for frame in frames {
            guard let ticket = await peer.prepareReplyPublication(frame) else { return false }
            prepared.append(ticket)
        }
        guard ReplyConnectionStopGate.commit(connection, { prepared.allSatisfy { $0.enqueue() } }) else { return false }
        for ticket in prepared { guard await ticket.result() == .sent else { return false } }
        return true
    }

    private func startRequestless(_ rig: ReplySegmentsRig) async throws -> ReplyDescriptor {
        let reply = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
                                    audioStreamID: UUID())
        let frame = recipientAudio(reply, sequence: 0)
        try #require(await rig.first.peer.deliverRequestlessReply(frame).succeeded)
        #expect(try await recipientSocketReceive(on: rig.first.socket) == frame)
        return reply
    }

    @Test func finalCheckRefusesAControlAcceptedAfterPreparation() async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let descriptor = ReplyDescriptor(id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target)
            let frame = recipientText(descriptor)
            let prepared = try #require(await rig.first.peer.prepareReplyPublication(frame))
            let connection = await rig.first.session.connectionID
            let control = ReplyConnectionStopGate.captureControl(connection)
            #expect(!prepared.enqueue())
            #expect(ReplyConnectionStopGate.complete(control))
            #expect(prepared.enqueue())
            #expect(await prepared.result() == .sent)
            #expect(try await recipientSocketReceive(on: rig.first.socket) == frame)
        }
    }
}

private extension ReplyFrameDelivery {
    var succeeded: Bool { if case .delivered = self { true } else { false } }
}
