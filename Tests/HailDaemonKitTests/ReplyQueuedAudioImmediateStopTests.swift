#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ReplyQueuedAudioImmediateStopTests {
    @Test(arguments: [false, true])
    func playbackCutPrecedesHeldTargetResolution(deviceReport: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        let snapshot = VoiceStopConfirmationHold(), entered = VoiceStopConfirmationHold()
        let timeout = VoiceStopConfirmationHold()
        var stopping: Task<Void, Never>?
        do {
            try await rig.start()
            let listener = rig.env.listener
            let connection = try #require(rig.env.router.activeConnection())
            let reply = uncorrelatedDescriptor(audio: true)
            let first = recipientAudio(reply, sequence: 0)
            #expect(try await listener.publish(first) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "in-flight audio") == first)
            stopping = Task {
                await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                    await ReplyAudioEnqueueTesting.$beforeStopSnapshot.withValue({
                        entered.release()
                        await snapshot.wait()
                    }, operation: {
                        await stopPlayback(rig, connection: connection, deviceReport: deviceReport)
                    })
                })
            }
            await entered.wait()
            // Neither the snapshot nor timeout is released until after observing the wire stop and retirement.
            #expect(try await receiveFrame(on: rig.socket, step: "stop before resolution").payload
                == .control(.stopPlayback))
            await #expect(throws: LocalReplyRefusal.replyStopped) {
                try await listener.publish(recipientAudio(reply, sequence: 1, final: true))
            }
            try await barrier(on: rig.socket, step: "retired flight sends no remaining audio")
            snapshot.release()
            await stopping?.value
        } catch {
            snapshot.release(); timeout.release()
            await stopping?.value
            await rig.finish()
            throw error
        }
        timeout.release()
        await rig.finish()
    }

    private func stopPlayback(_ rig: DeviceVoiceStopRig, connection: UUID, deviceReport: Bool) async {
        if deviceReport {
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
        } else {
            #expect(await rig.env.listener.stopReplyPlayback(connection: connection, markQueuedAudio: true)
                == "stopped")
        }
    }
}
#endif
