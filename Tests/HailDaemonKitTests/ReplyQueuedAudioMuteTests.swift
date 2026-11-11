#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioMuteTests {
    @Test func spokenMuteLeavesQueuedAudioAdmissionUnchanged() async throws {
        let fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, mute."))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let outcomes = Mutex<[String]>([])
        let library = AmbientAckLibrary(clips: ["confirmmuted": [AmbientWiringVoiceMuteTests.muted]])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2), acknowledgements: library,
            onEvent: { event in
                if event.event == "ambient_voice_mute" { outcomes.withLock { $0.append(event.detail ?? "") } }
            })
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: env.port,
                selecting: [RecipientTestRig.target], capabilities: [PlaybackStop.capability, ReplyMute.capability])
            defer { pair.close() }
            let socket = pair.sockets[0], reply = uncorrelatedDescriptor(audio: true)
            let text = recipientText(reply), frame = recipientAudio(reply, sequence: 0, final: true)
            #expect(try await env.listener.publish(text) == 1)
            #expect(try await receiveFrame(on: socket, step: "queued text") == text)
            let ticket = try await queuedAudioTicket(env.listener)
            try await recipientSocketSend(audio(UUID(), 0), on: socket)
            try #require(await eventually { !outcomes.withLock { $0 }.isEmpty })
            #expect(try await receiveFrame(on: socket, step: "mute stop").payload == .control(.stopPlayback))
            let words = try await receiveFrame(on: socket, step: "mute confirmation")
            guard case .text(let confirmation) = words.payload else { throw QueuedMuteTestError.expectedText }
            #expect(confirmation.text == "Muted.")
            let clip = try await receiveFrame(on: socket, step: "mute confirmation audio")
            guard case .audio = clip.payload else { throw QueuedMuteTestError.expectedAudio }
            #expect(try await receiveFrame(on: socket, step: "mute").payload == .control(.setReplyMute(muted: true)))
            #expect(try await env.listener.replyAudio(.init(action: "check", ticket: ticket, frame: frame))
                == LocalReplyAudioReport())
            #expect(try await env.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: frame))
                == LocalReplyAudioReport())
            #expect(try await receiveFrame(on: socket, step: "queued audio still admitted") == frame)
            try await pair.boundedBarrier(step: "mute does not skip queued audio")
        } catch {
            await env.listener.stop(reason: "synthetic failure")
            throw error
        }
        await env.listener.stop(reason: "synthetic complete")
    }
}
private enum QueuedMuteTestError: Error { case expectedText, expectedAudio }
#endif
