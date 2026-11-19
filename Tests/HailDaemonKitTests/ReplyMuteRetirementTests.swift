#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ReplyMuteRetirementTests {
    /// Text and its Markdown card share one frame; exercise both encoded field orders.
    @Test(arguments: [false, true])
    func inFlightMuteDeliversPendingTextAndCardWithoutRevivingAudio(cardFirst: Bool) async throws {
        try await ReplyMuteSilencesTests().withMuteRig { env, socket, session, _ in
            let immediate = recipientDescriptor(try await env.rig.submit(on: session), audio: true)
            let delayed = recipientDescriptor(try await env.rig.submit(on: session), audio: true)
            for reply in [immediate, delayed] {
                let first = recipientAudio(reply, sequence: 0)
                #expect(try await env.listener.publish(first) == 1)
                #expect(try await receiveFrame(on: socket, step: "original audio") == first)
            }
            try await mute(env.listener, connection: session.connectionID, socket: socket)
            for reply in [immediate, delayed] {
                #expect(await session.replyRequests[try #require(reply.requestID)]?.audioStopped == true)
                #expect(await !env.listener.stoppedReplyIDs.contains(reply.id))
                #expect(await !session.hasStopped(recipientAudio(reply, sequence: 1)))
                try await refuseAudio(reply, listener: env.listener)
            }
            // No stop-ledger eviction or unmute may be needed to deliver this request's pending answer.
            try await deliverAnswer(immediate, cardFirst: cardFirst, listener: env.listener, socket: socket)
            try await overflowStopLedgers(listener: env.listener, session: session, socket: socket)
            try await deliverAnswer(delayed, cardFirst: cardFirst, listener: env.listener, socket: socket)
            for reply in [immediate, delayed] { try await refuseAudio(reply, listener: env.listener) }
            #expect(await env.listener.setReplyMute(false, connection: session.connectionID) == "sent")
            #expect(try await receiveFrame(on: socket, step: "unmute").payload
                == .control(.setReplyMute(muted: false)))
            for reply in [immediate, delayed] { try await refuseAudio(reply, listener: env.listener) }
            try await barrier(on: socket, step: "retired audio never reaches wire")
        }
    }

    private func overflowStopLedgers(
        listener: WebSocketListener, session: HostSession, socket: URLSessionWebSocketTask
    ) async throws {
        let sentinel = uncorrelatedDescriptor(audio: true)
        for index in 0..<(HostSession.playbackStopLimit + 1) {
            let replacement = index == 0 ? sentinel : uncorrelatedDescriptor(audio: true)
            let audio = recipientAudio(replacement, sequence: 0)
            #expect(try await listener.publish(audio) == 1)
            #expect(try await receiveFrame(on: socket, step: "later requestless audio") == audio)
            try await mute(listener, connection: session.connectionID, socket: socket)
            #expect(await listener.stoppedReplyIDs.contains(replacement.id))
            #expect(await session.hasStopped(audio))
            await #expect(throws: LocalReplyRefusal.replyStopped) {
                try await listener.publish(recipientAudio(replacement, sequence: 1, final: true))
            }
            await #expect(throws: LocalReplyRefusal.replyStopped) {
                try await listener.publish(recipientText(replacement))
            }
        }
        #expect(await !listener.stoppedReplyIDs.contains(sentinel.id))
        #expect(await !session.hasStopped(recipientAudio(sentinel, sequence: 1)))
    }

    private func refuseAudio(_ reply: ReplyDescriptor, listener: WebSocketListener) async throws {
        await #expect(throws: LocalReplyRefusal.noRecipient) {
            try await listener.publish(recipientAudio(reply, sequence: 1, final: true))
        }
    }

    private func deliverAnswer(
        _ reply: ReplyDescriptor, cardFirst: Bool, listener: WebSocketListener, socket: URLSessionWebSocketTask
    ) async throws {
        let frame = Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "Synthetic answer", reply: reply, metadata: "**Synthetic card**")))
        // Canonical encoding puts metadata first. Also decode the equivalent text-first payload.
        var json = try #require(String(bytes: FrameCoding.encode(frame), encoding: .utf8))
        if !cardFirst {
            json = json.replacingOccurrences(of: #""metadata":"**Synthetic card**","#, with: "")
                .replacingOccurrences(of: #""text":"Synthetic answer""#,
                                      with: #""text":"Synthetic answer","metadata":"**Synthetic card**""#)
        }
        let metadataPosition = try #require(json.range(of: #""metadata":"#)).lowerBound
        let textPosition = try #require(json.range(of: #""text":"#)).lowerBound
        #expect((metadataPosition < textPosition) == cardFirst)
        let decoded = try FrameCoding.decode(Data(json.utf8))
        #expect(decoded == frame)
        #expect(try await listener.publish(decoded) == 1)
        #expect(try await receiveFrame(on: socket, step: "retained text and card together") == frame)
    }

    @Test func unsupportedMuteStopsQueuedRequestlessAudioAndProactiveSpeech() async throws {
        try await ReplyMuteSilencesTests().withMuteRig(
            supported: false, additionalCapabilities: [SessionUpdateCard.capability, SessionUpdateCard.audioCapability]
        ) { env, socket, session, _ in
            _ = try await env.rig.submit(on: session)
            let queued = uncorrelatedDescriptor(audio: true)
            let frame = recipientAudio(queued, sequence: 0, final: true)
            let ticket = try #require(await env.listener.replyAudio(.init(action: "enqueue", frame: frame)).ticket)
            let text = recipientText(queued)
            #expect(try await env.listener.publish(text) == 1)
            #expect(try await receiveFrame(on: socket, step: "queued reply text") == text)
            let speech = NotifyingMuteSpeech()
            defer { speech.release.release() }
            await env.listener.enableSessionUpdates()
            await env.listener.configureSessionUpdateSpeech(speech)
            await submitStopUpdate(env.listener)
            let update = try await receiveStopUpdateCard(on: socket)
            await speech.entered.wait()
            let result = await env.listener.muteReplyPlayback(connection: session.connectionID)
            #expect(result.playback == "stopped" && result.mute == "unsupported")
            #expect(try await receiveFrame(on: socket, step: "fallback explicit stop").payload
                == .control(.stopPlayback))
            let controls = try await AmbientPrivacySwitchTests.untilPong(socket, step: "fallback controls drained")
            #expect(controls.contains(.control(.sessionUpdateCancel(update: update))))
            speech.release.release()
            let fence = await env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.renderer.results.withLock { $0 } == ["cancelled", "refused"])
            let checked = try await env.listener.replyAudio(.init(action: "check", ticket: ticket, frame: frame))
            #expect(checked.skipped && checked.reason == "stopped")
            let published = try await env.listener.replyAudio(.init(action: "publish", ticket: ticket, frame: frame))
            #expect(published.skipped)
            try await barrier(on: socket, step: "no queued or proactive PCM after fallback")
        }
    }

    private func mute(
        _ listener: WebSocketListener, connection: UUID, socket: URLSessionWebSocketTask
    ) async throws {
        #expect(await listener.muteReplyPlayback(connection: connection).mute == "sent")
        #expect(try await receiveFrame(on: socket, step: "retirement stop").payload == .control(.stopPlayback))
        #expect(try await receiveFrame(on: socket, step: "mute flag").payload == .control(.setReplyMute(muted: true)))
    }
}

private final class NotifyingMuteSpeech: SessionUpdateSpeechRendering {
    let entered = VoiceStopConfirmationHold()
    let release = VoiceStopConfirmationHold()
    let renderer: HeldStopUpdateSpeech

    init() { renderer = HeldStopUpdateSpeech(hold: release) }

    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        entered.release()
        try await renderer.render(text, publish: publish)
    }
}
#endif
