#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct SessionUpdateStopTests {
    @Test(arguments: [false, true], [false, true])
    func acceptedStopCancelsOnlyAudioBeforeFirstFrameOrMidstream(rightyo: Bool, midstream: Bool) async throws {
        let confirmation = VoiceStopConfirmationHold(), render = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(capabilities: stopUpdateCapabilities, hold: confirmation)
        let speech = HeldStopUpdateSpeech(hold: render, firstBeforeHold: midstream)
        do {
            try await rig.start()
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(speech)
            await submitStopUpdate(rig.env.listener)
            let update = try await receiveStopUpdateCard(on: rig.socket)
            try #require(await eventually { render.entered })
            if midstream { try await receiveStopUpdateAudio(on: rig.socket, update: update, sequence: 0, final: false) }
            if rightyo { try rig.releaseDismissal() } else { try await rig.report() }
            #expect(try await receiveFrame(on: rig.socket, step: "immediate cut").payload == .control(.stopPlayback))
            #expect(try await receiveFrame(on: rig.socket, step: "audio identity retraction").payload
                == .control(.sessionUpdateCancel(update: update)))
            try #require(await eventually { rig.details("session_update_speech_cancelled").count == 1 })
            #expect(rig.details("session_update_speech_cancelled") == [
                "reason=stopped update=\(update) connection_scoped=true"
            ])
            render.release()
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.results.withLock { $0 } == ["cancelled", "refused"])
            // Completed renderer plus an ordered socket barrier proves no late frame or card retraction.
            try await barrier(on: rig.socket, step: "stopped renderer joined; card remains")
            if !rightyo { try await verifyUpdateAfterStop(rig, previous: update) }
        } catch {
            render.release(); confirmation.release()
            await rig.finish()
            throw error
        }
        render.release(); confirmation.release()
        await rig.finish()
    }

    @Test func deviceAStopPreservesDeviceBRendererAndBufferedIdentity() async throws {
        let render = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(capabilities: stopUpdateCapabilities)
        let speech = HeldStopUpdateSpeech(hold: render, firstBeforeHold: true)
        do {
            // B owns the last input before A starts ambient listening. B's renderer stays running during A's stop.
            let other = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                selecting: [RecipientTestRig.target], capabilities: stopUpdateCapabilities)
            defer { other.close() }
            let socketB = other.sockets[0]
            try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                payload: .text(TextPayload(text: "Synthetic input"))), on: socketB)
            try await other.boundedBarrier(step: "B owns last input")
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(speech)
            await submitStopUpdate(rig.env.listener)
            let update = try await receiveStopUpdateCard(on: socketB)
            try await receiveStopUpdateAudio(on: socketB, update: update, sequence: 0, final: false)
            try #require(await eventually { render.entered })
            try await rig.start()
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "A accepted cut").payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            render.release()
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.results.withLock { $0 } == ["running", "completed"])
            try await receiveStopUpdateAudio(on: socketB, update: update, sequence: 1, final: true)
            #expect(rig.details("session_update_speech_cancelled") == [])
            try await barrier(on: rig.socket, step: "A got no B cancellation")
            try await other.boundedBarrier(step: "B got no cancellation")
            _ = await rig.env.listener.sessionUpdate(.init(action: .quietOn))
            #expect(try await receiveFrame(on: socketB, step: "B buffered receipt preserved").payload
                == .control(.sessionUpdateCancel(update: update)))
        } catch { render.release(); await rig.finish(); throw error }
        render.release()
        await rig.finish()
    }
}
#endif
