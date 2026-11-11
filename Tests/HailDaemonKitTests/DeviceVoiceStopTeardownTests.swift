#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct DeviceVoiceStopTeardownTests {
    @Test func lateReportsAndDismissalsDoNotRecreateConnectionState() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            _ = try await receiveFrame(on: rig.socket, step: "accepted stop")
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            #expect(rig.env.router.state.withLock { $0.voiceStopLogs[connection] != nil })
            await rig.env.listener.stop(reason: "synthetic teardown")
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            await rig.env.router.confirmStop(
                receipt, playback: "stopped", on: connection, target: RecipientTestRig.target,
                listener: rig.env.listener
            )
            #expect(rig.env.router.state.withLock { $0.voiceStopLogs[connection] == nil })
            #expect(rig.env.router.state.withLock { $0.deviceVoiceStops[connection] == nil })
            #expect(rig.env.router.state.withLock { $0.stopConfirmations[connection] == nil })
            #expect(rig.details("ambient_stop_confirmed") == ["outcome=skipped reason=connection_closed"])
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func aCompletedConfirmationRemovesItsEmptyTokenSet() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            await rig.env.router.confirmStop(
                receipt, playback: "stopped", on: connection, target: RecipientTestRig.target,
                listener: rig.env.listener
            )
            #expect(rig.env.router.state.withLock { $0.stopConfirmations[connection] == nil })
            #expect(rig.details("ambient_stop_confirmed") == ["clip=confirmstopped/0 outcome=sent"])
            let text = try await receiveFrame(on: rig.socket, step: "confirmation text")
            guard case .text(let words) = text.payload else { throw VoiceStopTeardownError.expectedText }
            #expect(words.text == "Stopped.")
            let audio = try await receiveFrame(on: rig.socket, step: "confirmation audio")
            let reply = try #require(words.reply)
            let stream = try #require(reply.audioStreamID)
            #expect(words.isFinal)
            #expect(audio.target == RecipientTestRig.target)
            #expect(audio.payload == .audio(AudioPayload(
                codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: stream,
                isFinal: true, bytes: AmbientWiringStopConfirmationTests.stopped.pcm, reply: reply
            )))
            try await barrier(on: rig.socket, step: "confirmation complete")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func teardownRetiresAHeldConfirmationWithTheConnectionClosedReason() async throws {
        let hold = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(hold: hold)
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            let confirmation = Task {
                await rig.env.router.confirmStop(
                    receipt, playback: "stopped", on: connection, target: RecipientTestRig.target,
                    listener: rig.env.listener
                )
            }
            try #require(await eventually { hold.entered })
            #expect(rig.env.router.state.withLock { $0.stopConfirmations[connection]?.count == 1 })
            await rig.env.gate.end(connection: connection)
            rig.env.router.stop(connection: connection)
            hold.release()
            await confirmation.value
            #expect(rig.details("ambient_stop_confirmed") == ["outcome=skipped reason=connection_closed"])
            #expect(rig.env.router.state.withLock { $0.stopConfirmations[connection] == nil })
            try await barrier(on: rig.socket, step: "teardown confirmation sends no clip")
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func listenerTeardownNormalizesAHeldConfirmationOutcome() async throws {
        let hold = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(hold: hold)
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            let confirmation = Task {
                await rig.env.router.confirmStop(
                    receipt, playback: "stopped", on: connection, target: RecipientTestRig.target,
                    listener: rig.env.listener
                )
            }
            try #require(await eventually { hold.entered })
            await rig.env.listener.stop(reason: "synthetic listener-wide teardown")
            hold.release()
            await confirmation.value
            #expect(rig.details("ambient_stop_confirmed") == ["outcome=skipped reason=connection_closed"])
            #expect(rig.env.router.state.withLock { $0.stopConfirmations[connection] == nil })
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    private var receipt: RightyoDismissReceipt {
        RightyoDismissReceipt(reason: "stop-phrase", scope: ["playback"], withdrawn: 0, alreadyDelivered: 0,
                              owner: true)
    }
}
private enum VoiceStopTeardownError: Error { case expectedText }
#endif
