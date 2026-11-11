#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioRaceTests {
    @Test func coalescedDeviceReportStillMarksANewlyQueuedJob() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "initial stop").payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            let reply = uncorrelatedDescriptor(audio: true), ticket = try await queuedAudioTicket(rig.env.listener)
            let text = recipientText(reply)
            #expect(try await rig.env.listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "text between stops") == text)
            rig.observation.clock.withLock { $0 = $0.advanced(by: .milliseconds(100)) }
            try await rig.report()
            try #require(await eventually { rig.details("ambient_voice_stop_ignored") == ["reason=coalesced"] })
            let decision = try await rig.env.listener.replyAudio(.init(
                action: "check", ticket: ticket, frame: recipientAudio(reply, sequence: 0)
            ))
            #expect(decision.skipped)
            #expect(rig.details("reply_audio_skipped") == ["reason=stopped request=none ticket=\(ticket.position)"])
            try await barrier(on: rig.socket, step: "coalesced stop retires queue without an extra frame")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func stopAfterRouteResolutionStillRefusesTheFinalAudioEnqueue() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let hold = VoiceStopConfirmationHold()
        do {
            try await rig.start()
            let reply = uncorrelatedDescriptor(audio: true)
            let text = recipientText(reply), audio = recipientAudio(reply, sequence: 0)
            #expect(try await rig.env.listener.publish(text) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "race text") == text)
            let ticket = try await queuedAudioTicket(rig.env.listener)
            let publication = Task {
                try await ReplyAudioEnqueueTesting.$beforeEnqueue.withValue({ await hold.wait() }, operation: {
                    try await rig.env.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: audio))
                })
            }
            try #require(await eventually { hold.entered })
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "race stop").payload == .control(.stopPlayback))
            try #require(await eventually { !rig.details("ambient_dismissed").isEmpty })
            hold.release()
            #expect(try await publication.value == LocalReplyAudioReport(skipped: true))
            #expect(rig.details("reply_audio_skipped") == ["reason=stopped request=none ticket=\(ticket.position)"])
            try await barrier(on: rig.socket, step: "final enqueue sent no audio")
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
#endif
