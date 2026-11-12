#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioProbeTests {
    @Test func requestOwnerProbeDoesNotConsumePublicationOrPin() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: port, selecting: [RecipientTestRig.target])
            defer { pair.close() }
            let context = try await pair.submitInput(on: 0, rig: rig)
            let reply = recipientDescriptor(context, audio: true)
            let frame = recipientAudio(reply, sequence: 0, final: true)
            let peer = try #require(await listener.peers.values.first)
            let session = await peer.session
            let before = try #require(await session.replyRequests[context.id])
            let ticket = try await queuedAudioTicket(listener)
            for _ in 0..<2 {
                #expect(try await listener.replyAudio(.init(action: "check", ticket: ticket, frame: frame))
                    == LocalReplyAudioReport())
            }
            let after = try #require(await session.replyRequests[context.id])
            #expect(after.frames == before.frames && after.audioSequence == before.audioSequence)
            #expect(after.descriptor == before.descriptor && after.firstFrameAt == before.firstFrameAt)
            #expect(await session.repliesInFlight == [])
            let ledger = await listener.lastInput
            #expect(ledger.pinned(reply.id, target: RecipientTestRig.target) == nil)
            try await pair.boundedBarrier(step: "probe sends nothing")
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: frame))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: pair.sockets[0], step: "owner publish after probe") == frame)
            #expect(await session.replyRequests[context.id]?.audioSequence == 1)
            try await pair.boundedBarrier(step: "owner complete")
        } catch {
            await listener.stop(reason: "synthetic failure")
            throw error
        }
        await listener.stop(reason: "synthetic complete")
    }

    @Test(arguments: [false, true])
    func unpinnedAudioProbeUsesSingleSelectorOrAmbientOwner(twoSelectors: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [twoSelectors ? RecipientTestRig.target : nil])
            defer { other.close() }
            let frame = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let ticket = try await queuedAudioTicket(rig.env.listener)
            #expect(await rig.env.listener.lastInputRoute(frame) == nil)
            #expect(try await rig.env.listener.replyAudio(.init(action: "check", ticket: ticket, frame: frame))
                == LocalReplyAudioReport())
            #expect(await rig.env.listener.lastInputRoute(frame) == nil)
            try await rig.pair.boundedBarrier(step: "fallback probe silent")
            #expect(try await rig.env.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: frame))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "fallback audio") == frame)
            let path = twoSelectors ? "ambient_owner" : "single_selector"
            #expect(rig.details("reply_routed") == ["path=\(path)"])
            try await rig.pair.boundedBarrier(step: "fallback complete")
            try await other.boundedBarrier(step: "other gets no audio")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func privacyDecisionBeforeExitCannotMarkPostExitTicket() async throws {
        let rig = try await DuckRig(script: AmbientPrivacyConfirmAfterAckTests.heldSwitch(),
            clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability, PlaybackStop.capability])
        let hold = VoiceStopConfirmationHold()
        defer { hold.release(); rig.close() }
        do {
            try #require(await eventually { rig.details("ambient_duck_confirmed").count == 1 })
            let listener = rig.env.listener, connection = try #require(rig.connection())
            ReplyAudioEnqueueTesting.$afterPrivacyDecision.withValue({ await hold.wait() }, operation: {
                rig.env.router.ambientPrivacy(true, connection: connection)
            })
            AmbientPrivacyAckGateTests.go(rig.fake)
            try #require(await eventually { hold.entered })
            rig.env.router.ambientPrivacy(false, connection: connection)
            try #require(await eventually { await !listener.replyHold.holds(connection) })
            let audio = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            let fresh = try #require(await listener.replyAudio(.init(action: "enqueue", frame: audio)).ticket)
            hold.release()
            try #require(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
            _ = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "late entry stop complete")
            #expect(try await listener.replyAudio(.init(action: "publish", ticket: fresh, frame: audio))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: rig.socket, step: "post-exit job plays") == audio)
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test(arguments: [false, true])
    func queuedAudioStaysSilentAfterPrivacyEntry(withEntryClip: Bool) async throws {
        let rig = try await DuckRig(script: AmbientPrivacyConfirmAfterAckTests.heldSwitch(),
            clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability, PlaybackStop.capability])
        defer { rig.close() }
        do {
            try #require(await eventually { rig.details("ambient_duck_confirmed").count == 1 })
            let listener = rig.env.listener
            let reply = uncorrelatedDescriptor(audio: true), text = recipientText(reply)
            #expect(try await listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text before privacy") == text)
            let ticket = try await queuedAudioTicket(listener)
            let connection = try #require(rig.connection())
            rig.env.router.ambientPrivacy(true, connection: connection)
            try #require(await eventually { rig.details("ambient_privacy_replies").contains("dropped=0") })
            await #expect(throws: LocalReplyRefusal.privacyHeld) {
                try await listener.publish(recipientText(uncorrelatedDescriptor()))
            }
            if withEntryClip {
                AmbientPrivacyAckGateTests.go(rig.fake)
                try #require(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
            }
            // With no entry clip, withdraw before the child ack: announceEntry returns clip=nil.
            rig.env.router.ambientPrivacy(false, connection: connection)
            AmbientPrivacyAckGateTests.go(rig.fake)
            try #require(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
            if !withEntryClip { #expect(rig.details("ambient_duck_confirmed")[1].contains("withdrawn")) }
            try #require(await eventually { await !listener.replyHold.holds(connection) })
            _ = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "privacy confirmations complete")
            let frame = recipientAudio(reply, sequence: 0, final: true)
            #expect(try await listener.replyAudio(.init(action: "check", ticket: ticket, frame: frame)).skipped)
            await #expect(throws: LocalReplyRefusal.invalidReplyPayload) {
                try await listener.replyAudio(.init(action: "publish", ticket: ticket, frame: frame))
            }
            #expect(try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "queued audio silent").isEmpty)
            let laterText = recipientText(uncorrelatedDescriptor())
            #expect(try await listener.publish(laterText) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text after privacy") == laterText)
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
#endif
