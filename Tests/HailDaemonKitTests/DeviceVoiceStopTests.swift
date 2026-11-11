#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct DeviceVoiceStopTests {
    @Test func anActiveDeviceStopRetiresAllInFlightRepliesWithoutAConfirmation() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let replies = [uncorrelatedDescriptor(audio: true), uncorrelatedDescriptor(audio: true)]
            for reply in replies {
                let first = recipientAudio(reply, sequence: 0)
                try #require(await rig.env.listener.publish(first) == 1)
                #expect(try await receiveFrame(on: rig.socket, step: "reply audio") == first)
            }
            try await rig.report()
            #expect(try await receiveFrame(on: rig.socket, step: "idempotent stop").payload == .control(.stopPlayback))
            try #require(await eventually { !rig.details("ambient_dismissed").isEmpty })
            let expected = "reason=device-voice-stop scope=playback source=device withdrawn=0 delivered=0"
                + " playback=stopped latency_ms=42"
            #expect(rig.details("ambient_dismissed") == [expected])
            for reply in replies {
                await #expect(throws: LocalReplyRefusal.replyStopped) {
                    try await rig.env.listener.publish(recipientAudio(reply, sequence: 1, final: true))
                }
            }
            try await barrier(on: rig.socket, step: "device stop has no confirmation")
            #expect(rig.details("ambient_stop_confirmed").isEmpty)
            #expect(rig.env.router.activeConnection() != nil)
            let later = recipientAudio(uncorrelatedDescriptor(audio: true), sequence: 0, final: true)
            #expect(try await rig.env.listener.publish(later) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "later reply unchanged") == later)
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test(arguments: [false, true])
    func ignoredWithoutAnActiveStreamOrWhilePrivate(privateMode: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make(capabilities: [])
        do {
            if privateMode {
                try await rig.start()
                let connection = try #require(rig.env.router.activeConnection())
                // Seed the existing private state: this fixture deliberately has no privacy-control child.
                rig.env.router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
                #expect(rig.env.router.duckMode(connection: connection))
            }
            try await rig.report(latency: nil)
            try #require(await eventually { !rig.details("ambient_voice_stop_ignored").isEmpty })
            let reason = privateMode ? "private" : "no_active_stream"
            #expect(rig.details("ambient_voice_stop_ignored") == ["reason=\(reason)"])
            try await barrier(on: rig.socket, step: "ignored stop sends no frames")
            #expect(rig.details("ambient_dismissed").isEmpty)
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test(arguments: [0, 9, 10, 11])
    func rightyoConfirmationIsSuppressedOnlyWithinTenSeconds(seconds: Int) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            try await rig.report()
            _ = try await receiveFrame(on: rig.socket, step: "device stop")
            try #require(await eventually { !rig.details("ambient_dismissed").isEmpty })
            rig.advance(by: seconds)
            try rig.releaseDismissal()
            try #require(await eventually { !rig.details("ambient_stop_confirmed").isEmpty })
            #expect(try await receiveFrame(on: rig.socket, step: "RightyO stop").payload == .control(.stopPlayback))
            if seconds < 10 {
                #expect(rig.details("ambient_stop_confirmed") == ["outcome=skipped reason=device_stopped"])
            } else {
                let text = try await receiveFrame(on: rig.socket, step: "normal stop confirmation")
                guard case .text(let words) = text.payload else {
                    Issue.record("expected normal confirmation words")
                    await rig.finish()
                    return
                }
                #expect(words.text == "Stopped.")
                _ = try await receiveFrame(on: rig.socket, step: "normal confirmation audio")
                #expect(rig.details("ambient_stop_confirmed") == ["clip=confirmstopped/0 outcome=sent"])
            }
            try await barrier(on: rig.socket, step: "confirmation decision completed")
            #expect(rig.details("ambient_dismissed").count == 2)
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func anotherConnectionCannotStopTheActiveConnectionsReplies() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let other = try await FallbackSocketPair.boundedConnect(
                port: rig.env.port, selecting: [RecipientTestRig.target], capabilities: [PlaybackStop.capability]
            )
            defer { other.close() }
            try await recipientSocketSend(sessionFrame(payload: .control(.voiceStopped(latencyMs: 1))),
                                          on: other.sockets[0])
            try #require(await eventually { !rig.details("ambient_voice_stop_ignored").isEmpty })
            #expect(rig.details("ambient_voice_stop_ignored") == ["reason=no_active_stream"])
            try await other.boundedBarrier(step: "other device ignored")
            try await barrier(on: rig.socket, step: "active device untouched")
            #expect(rig.details("ambient_dismissed").isEmpty)
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
#endif
