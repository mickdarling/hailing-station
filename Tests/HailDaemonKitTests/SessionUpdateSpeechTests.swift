import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

private struct SyntheticSessionUpdateSpeech: SessionUpdateSpeechRendering {
    var begin: @Sendable () -> Void = {}
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        begin()
        try await publish(Data(repeating: 0, count: 480), true)
    }
}

@Suite(.serialized) struct SessionUpdateSpeechTests {
    private func request() -> LocalSessionUpdateRequest {
        .init(action: .submit, target: RecipientTestRig.target, priority: .action, text: "Synthetic finished")
    }

    @Test func configuredSpeechStillRequiresTheSeparateDeviceCapability() async throws {
        let renders = Mutex(0)
        let rig = try await SessionUpdateListenerRig.make()
        await rig.listener.configureSessionUpdateSpeech(SyntheticSessionUpdateSpeech {
            renders.withLock { $0 += 1 }
        })
        #expect(await rig.listener.sessionUpdate(request()).outcome == .delivered)
        let fence = await rig.listener.sessionUpdateFence
        await fence.joinSpeech()
        #expect(renders.withLock { $0 } == 0)
        await rig.listener.stop()
    }

    @Test func aCapableExactPeerGetsCardThenGuardedPCMThroughTheSameTransport() async throws {
        let sends = Mutex(0), renders = Mutex(0)
        let rig = try await SessionUpdateListenerRig.make(audio: true, send: { complete in
            sends.withLock { $0 += 1 }; complete(nil)
        })
        await rig.listener.configureSessionUpdateSpeech(SyntheticSessionUpdateSpeech {
            renders.withLock { $0 += 1 }
        })
        #expect(await rig.listener.sessionUpdate(request()).outcome == .delivered)
        let fence = await rig.listener.sessionUpdateFence
        await fence.joinSpeech()
        #expect(sends.withLock { $0 } == 2 && renders.withLock { $0 } == 1)
        await rig.listener.stop()
    }

    @Test func actualCardAudioAndCancellationRetainOneWireSourceAndTarget() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        await listener.enableSessionUpdates()
        await listener.configureSessionUpdateSpeech(SyntheticSessionUpdateSpeech())
        let port = try await listener.start()
        do {
            let (client, socket) = try recipientSocket(port: port)
            defer { socket.cancel(with: .normalClosure, reason: nil); client.invalidateAndCancel() }
            try await recipientSocketSend(helloFrame(capabilities:
                [SessionUpdateCard.capability, SessionUpdateCard.audioCapability]), on: socket)
            _ = try await recipientSocketReceive(on: socket)
            try await recipientSocketSend(sessionFrame(payload: .control(.select(
                targetID: RecipientTestRig.target))), on: socket)
            try await recipientSocketBarrier(on: socket, step: "selected speech destination")
            try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                payload: .text(TextPayload(text: "Synthetic input"))), on: socket)
            try await recipientSocketBarrier(on: socket, step: "accepted synthetic input")
            #expect(await listener.sessionUpdate(request()).outcome == .delivered)
            let card = try await recipientSocketReceive(on: socket)
            let audio = try await recipientSocketReceive(on: socket)
            guard case .control(.sessionUpdate(let update, _, _, _, _)) = card.payload,
                  case .audio(let pcm) = audio.payload else {
                Issue.record("expected actual update card then PCM"); await listener.stop(); return
            }
            #expect(card.source == "haild" && audio.source == card.source && pcm.reply?.hostID == card.source)
            #expect(card.target == RecipientTestRig.target && audio.target == card.target)
            #expect(pcm.reply?.targetID == card.target && pcm.reply?.sessionUpdateID == update)
            _ = await listener.sessionUpdate(.init(action: .quietOn))
            let cancellation = try await recipientSocketReceive(on: socket)
            #expect(cancellation.source == card.source && cancellation.target == card.target)
            #expect(cancellation.payload == .control(.sessionUpdateCancel(update: update)))
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    @Test func privacyOnOffDuringRenderCannotPublishOldAudio() async throws {
        let sends = Mutex(0)
        let rig = try await SessionUpdateListenerRig.make(audio: true, send: { complete in
            sends.withLock { $0 += 1 }; complete(nil)
        })
        let hold = await rig.listener.replyHold
        await rig.listener.configureSessionUpdateSpeech(SyntheticSessionUpdateSpeech {
            hold.set(true, connection: rig.connectionID)
            hold.set(false, connection: rig.connectionID)
        })
        #expect(await rig.listener.sessionUpdate(request()).outcome == .delivered)
        let fence = await rig.listener.sessionUpdateFence
        await fence.joinSpeech()
        #expect(sends.withLock { $0 } == 1, "the card completed before privacy; old audio did not enqueue")
        await rig.listener.stop()
    }

    @Test func taskReportsFromAnEarlierPrivacyEpochAreDropped() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        let hold = await rig.listener.replyHold, expected = hold.entryRevision
        hold.set(true, connection: rig.connectionID)
        hold.set(false, connection: rig.connectionID)
        let result = await SessionUpdatePrivacyScope.$expectedRevision.withValue(expected) {
            await rig.listener.sessionUpdate(request())
        }
        #expect(result.outcome == .dropped && result.reason == "private" && result.held == 0)
        await rig.listener.stop()
    }
}
