#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioTargetTests {
    @Test(arguments: [false, true])
    func reconnectBeforeAdmissionKeepsTextAndSkipsOldTicket(evictPin: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let listener = rig.env.listener, reply = uncorrelatedDescriptor(audio: true)
            let text = recipientText(reply), audio = recipientAudio(reply, sequence: 0, final: true)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text kept before reconnect") == text)
            let old = try await queuedAudioTicket(listener)
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "stop before reconnect")
                .payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            let connection = try #require(rig.env.router.activeConnection())
            if evictPin { await evict(reply, on: listener, connection: connection) }
            rig.pair.close()
            try #require(await eventually { await listener.peers.isEmpty })
            let fresh = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target], capabilities: [PlaybackStop.capability])
            defer { fresh.close() }
            #expect(try await listener.replyAudio(.init(action: "check", ticket: old, frame: audio)).skipped)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: old, frame: audio)).skipped)
            let audioOnly = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            #expect(try await listener.replyAudio(.init(action: "check", ticket: old, frame: audioOnly)).skipped)
            #expect(rig.details("reply_audio_skipped") == ["reason=stopped request=none ticket=\(old.position)"])
            try await fresh.boundedBarrier(step: "old ticket sends nothing after reconnect")
            let later = try await queuedAudioTicket(listener)
            #expect(try await listener.replyAudio(.init(action: "check", ticket: later, frame: audioOnly))
                == LocalReplyAudioReport())
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: later, frame: audioOnly))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: fresh.sockets[0], step: "post-stop reconnect audio") == audioOnly)
            try await fresh.boundedBarrier(step: "reconnect complete")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func evictedTextPinCannotRerouteStoppedAudioToLastInputB() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let listener = rig.env.listener, reply = uncorrelatedDescriptor(audio: true)
            let text = recipientText(reply)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text on A") == text)
            let ticket = try await queuedAudioTicket(listener)
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "A stops").payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            let connection = try #require(rig.env.router.activeConnection())
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target])
            defer { other.close() }
            let otherConnection = try #require(await listener.peers.values
                .first { $0.session.connectionID != connection }?.session.connectionID)
            await evict(reply, on: listener, connection: connection)
            let context = try await other.submitInput(on: 0, rig: rig.env.rig)
            #expect(context.connectionID == otherConnection)
            let audio = recipientAudio(reply, sequence: 0, final: true)
            #expect(await listener.lastInputRoute(audio)?.entry.connection == otherConnection)
            #expect(try await listener.replyAudio(.init(action: "check", ticket: ticket, frame: audio)).skipped)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio)).skipped)
            try await rig.pair.boundedBarrier(step: "A stays silent")
            try await other.boundedBarrier(step: "B gets no stopped audio")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    private func evict(_ reply: ReplyDescriptor, on listener: WebSocketListener, connection: UUID) async {
        let ledger = await listener.lastInput
        let entry = LastInputLedger.Entry(connection: connection, generation: UUID(), at: .now)
        for _ in 0..<LastInputLedger.pinLimit { ledger.pin(UUID(), target: RecipientTestRig.target, to: entry) }
        #expect(ledger.pinned(reply.id, target: RecipientTestRig.target) == nil)
    }

    @Test func targetMarksAreBoundedAndOutliveConnectionMarks() throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        let before = try queue.ticket()
        queue.stop(connection, targets: ["retained"])
        queue.forget(connection)
        if case .stopped = queue.enqueue(before, connection: UUID(), target: "retained", { true }) {} else {
            Issue.record("target stop must outlive teardown")
        }
        let after = try queue.ticket()
        if case .sent(true) = queue.enqueue(after, connection: UUID(), target: "retained", { true }) {} else {
            Issue.record("a later ticket must play")
        }
        for index in 0..<256 { queue.stop(connection, targets: ["target-\(index)"]) }
        if case .sent(true) = queue.enqueue(before, connection: UUID(), target: "retained", { true }) {} else {
            Issue.record("the oldest target mark must be evicted at capacity")
        }
        if case .stopped = queue.enqueue(after, connection: UUID(), target: "target-255", { true }) {} else {
            Issue.record("the newest target mark must remain")
        }
    }
}
#endif
