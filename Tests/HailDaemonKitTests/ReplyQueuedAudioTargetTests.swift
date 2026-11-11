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
            let text = recipientText(reply), audio = recipientAudio(reply, sequence: 0, final: true)
            let ticket = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text on A") == text)
            let connection = try #require(rig.env.router.activeConnection())
            let peer = try #require(await listener.peers.values.first)
            _ = await peer.session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
            await evict(reply, on: listener, connection: connection)
            // Evict BEFORE the stop, with T absent from A's current associations.
            let ledger = await listener.lastInput
            #expect(!ledger.targets(on: connection, inFlight: []).contains(RecipientTestRig.target))
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "A stops").payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target])
            defer { other.close() }
            let context = try await other.submitInput(on: 0, rig: rig.env.rig)
            #expect(context.connectionID != connection)
            #expect(await listener.lastInputRoute(audio)?.entry.connection == context.connectionID)
            #expect(try await listener.replyAudio(.init(action: "check", ticket: ticket, frame: audio)).skipped)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio)).skipped)
            try await rig.pair.boundedBarrier(step: "A stays silent")
            try await other.boundedBarrier(step: "B gets no stopped audio")
            let fresh = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let later = try #require(await listener.replyAudio(.init(action: "enqueue", frame: fresh)).ticket)
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: later, frame: fresh))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: other.sockets[0], step: "post-stop T plays on B") == fresh)
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}

extension ReplyQueuedAudioTargetTests {
    @Test func outstandingJobEvictionRaisesFloorAndConsumptionRemovesRecord() throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
        let reply = uncorrelatedDescriptor(audio: true), frame = recipientAudio(reply, sequence: 0)
        let old = try queue.ticket(frame: frame)
        queue.deliveredText(reply.id, to: connection)
        for _ in 0..<ReplyAudioQueue.jobLimit { _ = try queue.ticket(frame: frame) }
        if case .stopped = queue.enqueue(old, connection: nil, target: "unrelated", { true }) {} else {
            Issue.record("outstanding eviction must fail closed globally")
        }
        let fresh = try queue.ticket(frame: frame)
        queue.finish(fresh)
        queue.stop(connection, targets: [])
        queue.forget(connection)
        if case .sent(true) = queue.enqueue(fresh, connection: nil, target: RecipientTestRig.target, { true }) {} else {
            Issue.record("a finished ticket must leave no destination association")
        }
    }

    private func evict(_ reply: ReplyDescriptor, on listener: WebSocketListener, connection: UUID) async {
        let ledger = await listener.lastInput
        let entry = LastInputLedger.Entry(connection: connection, generation: UUID(), at: .now)
        for _ in 0..<LastInputLedger.pinLimit { ledger.pin(UUID(), target: "recipient:other", to: entry) }
        #expect(ledger.pinned(reply.id, target: RecipientTestRig.target) == nil)
    }

    @Test func delayedAcceptedMarkUsesCapturedPositionAndCannotLowerNewerMark() throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
        let old = try queue.ticket()
        let accepted = queue.captureStop(connection)
        let fresh = try queue.ticket()
        queue.stop(connection, targets: ["target"], through: accepted)
        for destination in [connection, UUID()] {
            if case .sent(true) = queue.enqueue(fresh, connection: destination, target: "target", { true }) {} else {
                Issue.record("a delayed stop cannot cover a fresh ticket")
            }
        }
        let newer = queue.captureStop(connection)
        queue.stop(connection, targets: ["target"], through: newer)
        queue.stop(connection, targets: ["target"], through: accepted)
        for ticket in [old, fresh] {
            if case .stopped = queue.enqueue(ticket, connection: nil, target: "target", { true }) {} else {
                Issue.record("an older delayed mark cannot lower a newer mark")
            }
        }
    }

    @Test func lateStopAfterTeardownCannotMarkAnotherTargetsQueuedJob() throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
        let ticket = try queue.ticket()
        let captured = queue.captureStop(connection)
        queue.forget(connection)
        queue.stop(connection, targets: ["late"], through: captured)
        queue.captureStop(connection)
        if case .sent(true) = queue.enqueue(ticket, connection: nil, target: "late", { true }) {} else {
            Issue.record("late callbacks cannot recreate a torn-down connection's target marks")
        }
    }

    @Test func targetMarksAreBoundedAndOutliveConnectionMarks() throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
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
        queue.register(connection)
        // Fill exactly to the bound, then evict the oldest mark ("retained", at before.position).
        for index in 0..<(ReplyAudioQueue.targetLimit - 1) {
            queue.stop(connection, targets: ["target-\(index)"])
        }
        queue.stop(connection, targets: ["overflow"])
        queue.forget(connection)
        for target in ["retained", "unrelated", "overflow"] {
            if case .stopped = queue.enqueue(before, connection: nil, target: target, { false }) {} else {
                Issue.record("eviction must leave pre-stop audio silent for \(target)")
            }
        }
        if case .sent(true) = queue.enqueue(after, connection: nil, target: "unrelated", { true }) {} else {
            Issue.record("an unrelated ticket above the evicted floor must play")
        }
        let later = try queue.ticket()
        for target in ["retained", "unrelated", "overflow"] {
            if case .sent(true) = queue.enqueue(later, connection: nil, target: target, { true }) {} else {
                Issue.record("a post-stop ticket must play for \(target)")
            }
        }
    }
}
#endif
