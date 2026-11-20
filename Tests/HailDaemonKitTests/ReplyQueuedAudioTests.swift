#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioTests {
    @Test(arguments: ["device", "rightyo"])
    func stopSkipsTwoEarlierJobsButNotTheNextJob(source: String) async throws {
        let hold = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(hold: hold)
        do {
            try await rig.start()
            let first = uncorrelatedDescriptor(audio: true), second = uncorrelatedDescriptor(audio: true)
            var tickets: [LocalReplyAudioTicket] = []
            for reply in [first, second] {
                let text = recipientText(reply)
                #expect(try await rig.env.listener.publish(text) == 1)
                #expect(try await receiveFrame(on: rig.socket, step: "queued text survives") == text)
                tickets.append(try await queuedAudioTicket(rig.env.listener))
            }
            #expect(tickets[0].position < tickets[1].position)
            if source == "device" { try await rig.report() } else { try rig.releaseDismissal() }
            #expect(try await receiveFrame(on: rig.socket, step: "stop").payload == .control(.stopPlayback))
            try #require(await eventually { !rig.details("ambient_dismissed").isEmpty })
            rig.observation.clock.withLock { $0 = $0.advanced(by: .milliseconds(100)) }
            let third = uncorrelatedDescriptor(audio: true)
            let after = try await queuedAudioTicket(rig.env.listener)
            #expect(after.position > tickets[1].position)
            for (reply, ticket) in zip([first, second], tickets) {
                let result = try await rig.env.listener.replyAudio(.init(
                    action: "check", ticket: ticket, frame: recipientAudio(reply, sequence: 0)
                ))
                #expect(result.skipped)
            }
            #expect(rig.details("reply_audio_skipped") == tickets.map {
                "reason=stopped request=none ticket=\($0.position)"
            })
            try await play(third, ticket: after, rig: rig)
            try await barrier(on: rig.socket, step: "no skipped audio or confirmation")
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        hold.release()
        await rig.finish()
    }

    private func play(_ reply: ReplyDescriptor, ticket: LocalReplyAudioTicket, rig: DeviceVoiceStopRig) async throws {
        let text = recipientText(reply), audio = recipientAudio(reply, sequence: 0, final: true)
        #expect(try await rig.env.listener.publish(text) == 1)
        #expect(try await receiveFrame(on: rig.socket, step: "post-stop text") == text)
        #expect(try await rig.env.listener.replyAudio(.init(action: "check", ticket: ticket, frame: audio))
            == LocalReplyAudioReport())
        #expect(try await rig.env.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
            == LocalReplyAudioReport())
        #expect(try await receiveFrame(on: rig.socket, step: "post-stop audio") == audio)
    }

    @Test func admissionBeforeStopDoesNotPermitLaterPublication() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let reply = uncorrelatedDescriptor(audio: true)
            let text = recipientText(reply), audio = recipientAudio(reply, sequence: 0)
            #expect(try await rig.env.listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text") == text)
            let ticket = try await queuedAudioTicket(rig.env.listener)
            #expect(try await rig.env.listener.replyAudio(.init(action: "check", ticket: ticket, frame: audio))
                == LocalReplyAudioReport())
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "stop").payload == .control(.stopPlayback))
            try #require(await eventually { !rig.details("ambient_dismissed").isEmpty })
            let result = try await rig.env.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
            #expect(result.skipped)
            #expect(rig.details("reply_audio_skipped") == ["reason=stopped request=none ticket=\(ticket.position)"])
            try await barrier(on: rig.socket, step: "no audio after admission-stop race")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}

func queuedAudioTicket(_ listener: WebSocketListener) async throws -> LocalReplyAudioTicket {
    try #require(await listener.replyAudio(.init(action: "enqueue")).ticket)
}
#endif
