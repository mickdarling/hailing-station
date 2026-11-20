#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Real spoken-mute wiring and loopback frames. Device mute/playout is covered by ReplyPlaybackMuteTests.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyMuteSilencesTests {
    @Test func answerToRequestAdmittedBeforeSpokenMuteKeepsTextAndCard() async throws {
        try await withMuteRig { env, socket, session, fake in
            let context = try await env.rig.submit(on: session)
            let reply = recipientDescriptor(context, audio: true)
            try await mute(env, socket: socket, fake: fake)
            #expect(await session.replyRequests[context.id] != nil)
            try await deliverAnswer(reply, listener: env.listener, socket: socket)
            #expect(await session.replyRequests[context.id] != nil)
            try await barrier(on: socket, step: "muted answer has no stop or refusal")
        }
    }

    @Test func muteCutsPlayingAudioPreservesPendingAnswerAndUnmuteAllowsLaterAudio() async throws {
        try await withMuteRig { env, socket, session, fake in
            let playing = recipientDescriptor(try await env.rig.submit(on: session), audio: true)
            let first = recipientAudio(playing, sequence: 0)
            #expect(try await env.listener.publish(first) == 1)
            #expect(try await receiveFrame(on: socket, step: "playing audio") == first)
            let pending = recipientDescriptor(try await env.rig.submit(on: session), audio: true)
            try await mute(env, socket: socket, fake: fake)
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await env.listener.publish(recipientAudio(playing, sequence: 1, final: true))
            }
            try await deliverAnswer(pending, listener: env.listener, socket: socket)
            #expect(await env.listener.setReplyMute(false, connection: session.connectionID) == "sent")
            #expect(try await receiveFrame(on: socket, step: "unmute").payload
                == .control(.setReplyMute(muted: false)))
            let later = recipientDescriptor(try await env.rig.submit(on: session), audio: true)
            try await deliverAnswer(later, listener: env.listener, socket: socket)
            try await barrier(on: socket, step: "stopped audio never reached transport")
        }
    }

    @Test(arguments: [false, true])
    func explicitStopStillRetractsPendingRequest(markQueued: Bool) async throws {
        try await ReplySegmentsRig.withDevices { rig in
            let context = try await rig.recipient.submit(on: rig.first.session)
            #expect(await rig.listener.stopReplyPlayback(
                connection: rig.first.session.connectionID, markQueuedAudio: markQueued
            ) == "stopped")
            #expect(try await recipientSocketReceive(on: rig.first.socket).payload == .control(.stopPlayback))
            #expect(await rig.first.session.replyRequests[context.id] == nil)
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await rig.listener.publish(recipientText(recipientDescriptor(context)))
            }
            try await recipientSocketBarrier(on: rig.first.socket)
        }
    }

    @Test func unsupportedMuteCancelsPendingRequestAndConfirmsStopped() async throws {
        let clips = AmbientAckLibrary(clips: [
            "confirmstopped": [AmbientWiringStopConfirmationTests.stopped]
        ])
        try await withMuteRig(supported: false, confirmations: clips) { env, socket, session, fake in
            let context = try await env.rig.submit(on: session)
            try await fake.start(on: env, socket: socket)
            #expect(try await receiveFrame(on: socket, step: "fallback stop").payload == .control(.stopPlayback))
            let confirmation = try await receiveFrame(on: socket, step: "honest fallback confirmation")
            guard case .text(let text) = confirmation.payload else {
                Issue.record("Expected Stopped confirmation"); return
            }
            #expect(text.text == "Stopped.")
            _ = try await receiveFrame(on: socket, step: "stopped clip")
            #expect(await session.replyRequests[context.id] == nil)
            let reply = recipientDescriptor(context, audio: true)
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await env.listener.publish(recipientAudio(reply, sequence: 0, final: true))
            }
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await env.listener.publish(recipientText(reply))
            }
            try await barrier(on: socket, step: "no pending PCM or unsupported mute flag")
        }
    }

    @Test func muteThenExplicitStopRetractsEveryEarlierRequest() async throws {
        try await withMuteRig { env, socket, session, fake in
            let beforeMute = try await env.rig.submit(on: session)
            try await mute(env, socket: socket, fake: fake)
            let beforeStop = try await env.rig.submit(on: session)
            #expect(await env.listener.stopReplyPlayback(connection: session.connectionID,
                                                        markQueuedAudio: true) == "stopped")
            #expect(try await receiveFrame(on: socket, step: "explicit stop").payload == .control(.stopPlayback))
            #expect(await env.listener.setReplyMute(false, connection: session.connectionID) == "sent")
            _ = try await receiveFrame(on: socket, step: "unmute cannot restore authority")
            for context in [beforeMute, beforeStop] {
                #expect(await session.replyRequests[context.id] == nil)
                await #expect(throws: LocalReplyRefusal.noRecipient) {
                    try await env.listener.publish(recipientText(recipientDescriptor(context)))
                }
            }
            let later = recipientDescriptor(try await env.rig.submit(on: session), audio: true)
            try await deliverAnswer(later, listener: env.listener, socket: socket)
            try await barrier(on: socket, step: "no authority revival or blocked later reply")
        }
    }

    func withMuteRig(
        supported: Bool = true, confirmations: AmbientAckLibrary? = nil, additionalCapabilities: [String] = [],
        _ body: (AmbientWiringRig, URLSessionWebSocketTask, HostSession, ReplyMuteFixture) async throws -> Void
    ) async throws {
        let fake = try makeStopMuteFixture()
        defer { fake.cleanUp() }
        let started = VoiceStopConfirmationHold()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2),
            acknowledgements: confirmations, onEvent: { event in
                if event.event == "ambient_started" { started.release() }
            })
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: env.port,
                selecting: [RecipientTestRig.target],
                capabilities: [PlaybackStop.capability] + (supported ? [ReplyMute.capability] : [])
                    + additionalCapabilities)
            defer { pair.close() }
            let peer = try #require(await env.listener.peers.values.first)
            try await body(env, pair.sockets[0], peer.session, ReplyMuteFixture(fake: fake, started: started))
        } catch { await env.listener.stop(reason: "synthetic failure"); throw error }
        await env.listener.stop(reason: "synthetic complete")
    }

    private func mute(_ env: AmbientWiringRig, socket: URLSessionWebSocketTask, fake: ReplyMuteFixture) async throws {
        try await fake.start(on: env, socket: socket)
        #expect(try await receiveFrame(on: socket, step: "mute stops playback").payload == .control(.stopPlayback))
        #expect(try await receiveFrame(on: socket, step: "device mute flag").payload
            == .control(.setReplyMute(muted: true)))
    }

    private func deliverAnswer(
        _ reply: ReplyDescriptor, listener: WebSocketListener, socket: URLSessionWebSocketTask
    ) async throws {
        let text = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "Synthetic answer", reply: reply, metadata: "**Synthetic card**")))
        #expect(try await listener.publish(text) == 1)
        #expect(try await receiveFrame(on: socket, step: "answer text and card") == text)
        // Mute belongs to the device: preserve audio for silent playback/replay, as before #1246.
        let audio = recipientAudio(reply, sequence: 0, final: true)
        #expect(try await listener.publish(audio) == 1)
        #expect(try await receiveFrame(on: socket, step: "audio under existing device mute") == audio)
    }
}
#endif
