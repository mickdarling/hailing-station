#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct SessionUpdateStopOrderingTests {
    @Test func rendererAndDeviceCancelDoNotWaitForQueuedTargetResolutionOrTimeout() async throws {
        let render = VoiceStopConfirmationHold(), snapshot = VoiceStopConfirmationHold()
        let entered = VoiceStopConfirmationHold(), timeout = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(capabilities: stopUpdateCapabilities)
        let speech = HeldStopUpdateSpeech(hold: render)
        var pending: Task<Void, Never>?
        defer { render.release(); snapshot.release(); timeout.release() }
        do {
            try await rig.start()
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(speech)
            await submitStopUpdate(rig.env.listener)
            let update = try await receiveStopUpdateCard(on: rig.socket)
            try #require(await eventually { render.entered })
            let connection = try #require(rig.env.router.activeConnection())
            let stop = startHeldUpdateStop(rig, connection: connection, snapshot: snapshot,
                                           entered: entered, timeout: timeout)
            pending = stop
            #expect(try await receiveFrame(on: rig.socket, step: "immediate cut").payload == .control(.stopPlayback))
            #expect(try await receiveFrame(on: rig.socket, step: "immediate update cancel").payload
                == .control(.sessionUpdateCancel(update: update)))
            await entered.wait()
            render.release()
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            #expect(speech.results.withLock { $0 } == ["cancelled", "refused"])
            #expect(rig.details("ambient_dismissed") == [])
            try await barrier(on: rig.socket, step: "no late speech while target resolution remains held")
            snapshot.release()
            await stop.value
        } catch {
            snapshot.release(); render.release(); timeout.release()
            await pending?.value
            await rig.finish()
            throw error
        }
        timeout.release()
        await rig.finish()
    }
}
#endif
