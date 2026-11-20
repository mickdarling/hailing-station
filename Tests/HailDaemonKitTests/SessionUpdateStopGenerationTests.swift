#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct SessionUpdateStopGenerationTests {
    @Test func stopAfterCardAdmissionRefusesRegistrationAndKeepsCard() async throws {
        let entered = VoiceStopConfirmationHold(), registration = VoiceStopConfirmationHold()
        let render = VoiceStopConfirmationHold()
        render.release()
        let rig = try await DeviceVoiceStopRig.make(capabilities: stopUpdateCapabilities)
        let speech = HeldStopUpdateSpeech(hold: render)
        var pending: Task<Void, Never>?
        do {
            try await rig.start()
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(speech)
            let delivery = heldDelivery(rig, entered: entered, registration: registration)
            pending = delivery
            let update = try await receiveStopUpdateCard(on: rig.socket)
            await entered.wait()
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "accepted stop before registration").payload
                == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            registration.release()
            await delivery.value
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.results.withLock { $0 } == [])
            #expect(!fence.speechBusy && fence.cancelProactive().isEmpty)
            #expect(rig.details("session_update_speech_cancelled") == [
                "reason=stopped_before_start update=\(update)"
            ])
            #expect(rig.details("session_update_speech_revoked") == [])
            // Delivery and speech are joined. Any audio, text or card retraction would precede this pong.
            try await barrier(on: rig.socket, step: "zero post-stop frames; card retained")
        } catch {
            registration.release(); await pending?.value
            await rig.finish(); throw error
        }
        await rig.finish()
    }

    @Test func cardAdmittedAfterGenerationBumpPlaysWhileStopResolutionIsPending() async throws {
        let snapshot = VoiceStopConfirmationHold(), entered = VoiceStopConfirmationHold()
        let timeout = VoiceStopConfirmationHold(), render = VoiceStopConfirmationHold()
        render.release()
        let rig = try await DeviceVoiceStopRig.make(capabilities: stopUpdateCapabilities)
        let speech = HeldStopUpdateSpeech(hold: render)
        var pending: Task<Void, Never>?
        do {
            try await rig.start()
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(speech)
            let connection = try #require(rig.env.router.activeConnection())
            let stop = startHeldUpdateStop(rig, connection: connection, snapshot: snapshot,
                                           entered: entered, timeout: timeout)
            pending = stop
            #expect(try await receiveFrame(on: rig.socket, step: "generation advanced before card").payload
                == .control(.stopPlayback))
            await entered.wait()
            await submitStopUpdate(rig.env.listener)
            let update = try await receiveStopUpdateCard(on: rig.socket)
            try await receiveStopUpdateAudio(on: rig.socket, update: update, sequence: 0, final: false)
            try await receiveStopUpdateAudio(on: rig.socket, update: update, sequence: 1, final: true)
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.results.withLock { $0 } == ["running", "completed"])
            #expect(rig.details("ambient_dismissed") == [])
            #expect(rig.details("session_update_speech_cancelled") == [])
            #expect(rig.details("session_update_speech_revoked") == [])
            try await barrier(on: rig.socket, step: "full update while stop resolution remains held")
            snapshot.release(); await stop.value
        } catch {
            snapshot.release(); timeout.release(); await pending?.value
            await rig.finish(); throw error
        }
        timeout.release()
        await rig.finish()
    }

    @Test func stopOnADoesNotRefuseBRegistrationAfterBCardAdmission() async throws {
        let entered = VoiceStopConfirmationHold(), registration = VoiceStopConfirmationHold()
        let render = VoiceStopConfirmationHold()
        render.release()
        let rig = try await DeviceVoiceStopRig.make(capabilities: stopUpdateCapabilities)
        let speech = HeldStopUpdateSpeech(hold: render)
        var pending: Task<Void, Never>?
        do {
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target], capabilities: stopUpdateCapabilities)
            defer { other.close() }
            let socketB = other.sockets[0]
            try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                payload: .text(TextPayload(text: "Synthetic input"))), on: socketB)
            try await other.boundedBarrier(step: "B owns last input")
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(speech)
            let delivery = heldDelivery(rig, entered: entered, registration: registration)
            pending = delivery
            let update = try await receiveStopUpdateCard(on: socketB)
            await entered.wait()
            try await rig.start()
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "A accepted stop").payload
                == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            registration.release(); await delivery.value
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            try await receiveStopUpdateAudio(on: socketB, update: update, sequence: 0, final: false)
            try await receiveStopUpdateAudio(on: socketB, update: update, sequence: 1, final: true)
            #expect(speech.results.withLock { $0 } == ["running", "completed"])
            #expect(rig.details("session_update_speech_cancelled") == [])
            #expect(rig.details("session_update_speech_revoked") == [])
            try await other.boundedBarrier(step: "B completes without retraction")
            try await barrier(on: rig.socket, step: "A receives no B frames")
        } catch {
            registration.release(); await pending?.value
            await rig.finish(); throw error
        }
        await rig.finish()
    }

    private func heldDelivery(
        _ rig: DeviceVoiceStopRig, entered: VoiceStopConfirmationHold, registration: VoiceStopConfirmationHold
    ) -> Task<Void, Never> {
        Task {
            await SessionUpdatePrivacyScope.$beforeSpeechCapabilities.withValue({
                entered.release()
                await registration.wait()
            }, operation: { await submitStopUpdate(rig.env.listener) })
        }
    }
}
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct SessionUpdateStopRevocationTests {
    @Test func runningJobRevocationHasItsOwnContentFreeLog() async throws {
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
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "running stop").payload == .control(.stopPlayback))
            #expect(try await receiveFrame(on: rig.socket, step: "buffered receipt retraction").payload
                == .control(.sessionUpdateCancel(update: update)))
            render.release()
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(rig.details("session_update_speech_revoked") == ["reason=stopped_running update=\(update)"])
            #expect(rig.details("session_update_speech_cancelled") == [
                "reason=stopped update=\(update) connection_scoped=true"
            ])
            #expect(speech.results.withLock { $0 } == ["cancelled", "refused"])
            try await barrier(on: rig.socket, step: "revoked job cannot publish")
        } catch { render.release(); await rig.finish(); throw error }
        await rig.finish()
    }
}
#endif
