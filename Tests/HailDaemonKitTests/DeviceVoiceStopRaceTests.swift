#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct DeviceVoiceStopRaceTests {
    @Test func aDeviceStopRetiresAHeldConfirmationEvenAfterTheWindowExpires() async throws {
        let hold = VoiceStopConfirmationHold()
        let rig = try await DeviceVoiceStopRig.make(hold: hold)
        do {
            try await rig.start()
            try rig.releaseDismissal()
            #expect(try await receiveFrame(on: rig.socket, step: "RightyO stop").payload == .control(.stopPlayback))
            try #require(await eventually { hold.entered })
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "device stop").payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 2 })
            rig.advance(by: 11)
            hold.release()
            try #require(await eventually { !rig.details("ambient_stop_confirmed").isEmpty })
            #expect(rig.details("ambient_stop_confirmed") == ["outcome=skipped reason=device_stopped"])
            try await barrier(on: rig.socket, step: "retired confirmation sends no clip frames")
        } catch {
            hold.release()
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func aStopOnADifferentConnectionDoesNotSuppressTheNewOwnersConfirmation() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let first = try #require(rig.env.router.activeConnection())
            try await rig.report()
            #expect(try await receiveFrame(
                on: rig.socket, step: "first device stop"
            ).payload == .control(.stopPlayback))
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            let other = try await FallbackSocketPair.boundedConnect(
                port: rig.env.port, selecting: [RecipientTestRig.target], capabilities: [PlaybackStop.capability]
            )
            defer { other.close() }
            try await rig.start(on: other.sockets[0], replacing: first)
            // The retired child may also emit after release; this assertion addresses only the new owner's socket.
            try rig.releaseDismissal()
            #expect(try await receiveFrame(
                on: other.sockets[0], step: "new owner stop"
            ).payload == .control(.stopPlayback))
            let text = try await receiveFrame(on: other.sockets[0], step: "new owner confirmation")
            guard case .text(let words) = text.payload else { throw DeviceVoiceStopTestError.expectedText }
            #expect(words.text == "Stopped.")
            let audio = try await receiveFrame(on: other.sockets[0], step: "new owner confirmation audio")
            let reply = try #require(words.reply)
            let stream = try #require(reply.audioStreamID)
            #expect(words.isFinal)
            #expect(audio.target == RecipientTestRig.target)
            #expect(audio.payload == .audio(AudioPayload(
                codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: stream,
                isFinal: true, bytes: AmbientWiringStopConfirmationTests.stopped.pcm, reply: reply
            )))
            try await other.boundedBarrier(step: "new owner confirmation complete")
            try #require(await eventually {
                rig.details("ambient_stop_confirmed").contains("clip=confirmstopped/0 outcome=sent")
            })
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test(arguments: [false, true])
    func queuedOwnershipChangesRefuseReports(reload: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            // Seed the exact queued state synchronously; no sleeping child or cooperative worker is blocked.
            rig.env.router.state.withLock {
                if reload {
                    $0.reloading = true
                } else {
                    let stream = UUID()
                    $0.newestStart = stream
                    $0.queue.append(.started(stream: stream, connection: UUID(), target: RecipientTestRig.target))
                }
            }
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            #expect(rig.details("ambient_voice_stop_ignored") == ["reason=no_active_stream"])
            #expect(rig.details("ambient_dismissed").isEmpty)
            try await barrier(on: rig.socket, step: "pending ownership sends no stop")
            rig.env.router.state.withLock { $0.reloading = false; $0.queue.removeAll() }
        } catch {
            rig.env.router.state.withLock { $0.reloading = false; $0.queue.removeAll() }
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func teardownClearsTheWindowForANewStreamOnTheSameConnection() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            try await rig.report()
            _ = try await receiveFrame(on: rig.socket, step: "old stream stop")
            try #require(await eventually { rig.details("ambient_dismissed").count == 1 })
            await rig.env.gate.end(connection: connection)
            rig.env.router.stop(connection: connection)
            try #require(await eventually { rig.env.router.liveRuns == 0 })
            try await rig.start()
            #expect(rig.env.router.activeConnection() == connection)
            try rig.releaseDismissal()
            #expect(try await receiveFrame(
                on: rig.socket, step: "fresh stream stop"
            ).payload == .control(.stopPlayback))
            let text = try await receiveFrame(on: rig.socket, step: "fresh stream confirmation")
            guard case .text(let words) = text.payload else { throw DeviceVoiceStopTestError.expectedText }
            #expect(words.text == "Stopped.")
            let audio = try await receiveFrame(on: rig.socket, step: "fresh stream confirmation audio")
            let reply = try #require(words.reply)
            let stream = try #require(reply.audioStreamID)
            #expect(words.isFinal)
            #expect(audio.target == RecipientTestRig.target)
            #expect(audio.payload == .audio(AudioPayload(
                codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0, streamID: stream,
                isFinal: true, bytes: AmbientWiringStopConfirmationTests.stopped.pcm, reply: reply
            )))
            try #require(await eventually { !rig.details("ambient_stop_confirmed").isEmpty })
            #expect(rig.details("ambient_stop_confirmed") == ["clip=confirmstopped/0 outcome=sent"])
            try await barrier(on: rig.socket, step: "fresh confirmation complete")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
private enum DeviceVoiceStopTestError: Error { case expectedText }
#endif
