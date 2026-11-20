#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct SessionUpdateStopRegressionTests {
    @Test(arguments: [false, true])
    func quietAndPrivacyStillCancelGlobalSpeechWithoutDroppingCard(privacy: Bool) async throws {
        let render = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(capabilities: stopUpdateCapabilities)
        let speech = HeldStopUpdateSpeech(hold: render)
        do {
            try await rig.start()
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(speech)
            await submitStopUpdate(rig.env.listener)
            let update = try await receiveStopUpdateCard(on: rig.socket)
            try #require(await eventually { render.entered })
            if privacy {
                // Real privacy-entry hold/observer: the cancellation notification is the completion barrier.
                let connection = try #require(rig.env.router.activeConnection())
                rig.env.router.holdReplies(connection, listener: rig.env.listener)
            } else { _ = await rig.env.listener.sessionUpdate(.init(action: .quietOn)) }
            #expect(try await receiveFrame(on: rig.socket, step: "global audio retraction").payload
                == .control(.sessionUpdateCancel(update: update)))
            render.release()
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.results.withLock { $0 } == ["cancelled", "refused"])
            #expect(fence.cancelProactive().map(\.update) == [])
            try await barrier(on: rig.socket, step: "quiet/privacy left the delivered card intact")
        } catch { render.release(); await rig.finish(); throw error }
        render.release()
        await rig.finish()
    }

    @Test func spokenMuteKeepsRunningSessionUpdateSpeech() async throws {
        let fake = try makeStopMuteFixture()
        defer { fake.cleanUp() }
        let events = Mutex<[WebSocketListenerEvent]>([]), render = VoiceStopConfirmationHold()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2),
            onEvent: { event in events.withLock { $0.append(event) } },
            onListenerEvent: { event in events.withLock { $0.append(event) } })
        let speech = HeldStopUpdateSpeech(hold: render, firstBeforeHold: true)
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: env.port,
                selecting: [RecipientTestRig.target], capabilities: stopUpdateCapabilities + [ReplyMute.capability])
            defer { pair.close() }
            let socket = pair.sockets[0]
            try await recipientSocketSend(audio(UUID(), 0), on: socket)
            try #require(await eventually { env.router.activeConnection() != nil })
            await env.listener.enableSessionUpdates()
            await env.listener.configureSessionUpdateSpeech(speech)
            await submitStopUpdate(env.listener)
            let update = try await receiveStopUpdateCard(on: socket)
            try await receiveStopUpdateAudio(on: socket, update: update, sequence: 0, final: false)
            try #require(await eventually { render.entered })
            try Data().write(to: fake.directory.appendingPathComponent("release"))
            #expect(try await receiveFrame(on: socket, step: "mute cuts current playback").payload
                == .control(.stopPlayback))
            #expect(try await receiveFrame(on: socket, step: "mute applied").payload
                == .control(.setReplyMute(muted: true)))
            render.release()
            let fence = await env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.results.withLock { $0 } == ["running", "completed"])
            try await receiveStopUpdateAudio(on: socket, update: update, sequence: 1, final: true)
            try await pair.boundedBarrier(step: "mute never retracted session-update audio")
            #expect(events.withLock { $0.filter { $0.event == "session_update_speech_cancelled" }.count } == 0)
            #expect(fence.cancelProactive().map(\.update) == [update])
        } catch { render.release(); await env.listener.stop(); throw error }
        render.release()
        await env.listener.stop()
    }
}
#endif
