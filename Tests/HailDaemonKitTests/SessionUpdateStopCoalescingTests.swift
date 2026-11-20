#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

private struct StopFollowupSpeech: SessionUpdateSpeechRendering {
    let kind: String
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        try await publish(kind == "empty_final" ? Data() : Data(repeating: 0, count: 480), kind != "streaming")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct SessionUpdateStopCoalescingTests {
    @Test(arguments: ["streaming", "final_only", "empty_final"])
    func admittedSessionUpdateAudioRequiresAnotherDeviceStop(kind: String) async throws {
        let rig = try await DeviceVoiceStopRig.make(capabilities:
            [PlaybackStop.capability, SessionUpdateCard.capability, SessionUpdateCard.audioCapability])
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            await rig.env.listener.enableSessionUpdates()
            await rig.env.listener.configureSessionUpdateSpeech(StopFollowupSpeech(kind: kind))
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            #expect(try await receiveFrame(on: rig.socket, step: "initial stop").payload == .control(.stopPlayback))
            let peer = try #require(await rig.env.listener.peers.values.first)
            let revision = await peer.session.replyFlightRevision
            rig.observation.clock.withLock { $0 = $0.advanced(by: .milliseconds(200)) }
            #expect(await rig.env.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                priority: .action, text: "Synthetic finished")).outcome == .delivered)
            let fence = await rig.env.listener.sessionUpdateFence
            await fence.joinSpeech()
            let card = try await receiveFrame(on: rig.socket, step: "update card")
            let audio = try await receiveFrame(on: rig.socket, step: "update audio")
            guard case .control(.sessionUpdate(let update, _, _, _, _)) = card.payload,
                  case .audio(let pcm) = audio.payload else {
                Issue.record("expected session-update card then audio"); await rig.finish(); return
            }
            #expect(pcm.reply?.sessionUpdateID == update && pcm.sequence == 0)
            #expect(pcm.isFinal == (kind != "streaming"))
            #expect(pcm.bytes.count == (kind == "empty_final" ? 0 : 480))
            #expect(await peer.session.replyFlightRevision == revision &+ 1)
            rig.observation.clock.withLock { $0 = $0.advanced(by: .milliseconds(300)) }
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            #expect(try await receiveFrame(on: rig.socket, step: "follow-up stop").payload == .control(.stopPlayback))
            #expect(try await receiveFrame(on: rig.socket, step: "session-update retraction").payload
                == .control(.sessionUpdateCancel(update: update)))
            #expect(rig.details("ambient_dismissed").count == 2)
            #expect(rig.details("ambient_voice_stop_ignored").isEmpty)
            try await barrier(on: rig.socket, step: "follow-up stop complete")
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
}
#endif
