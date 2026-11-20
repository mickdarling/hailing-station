#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct DeviceVoiceStopAdmissionTests {
    @Test(arguments: [false, true])
    func actualListenerAdvertisesOnlyWithAmbientWiring(wired: Bool) async throws {
        let rig = try await DeviceVoiceStopRig.make(ambientWired: wired)
        do {
            let (session, socket) = try recipientSocket(port: rig.env.port)
            defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
            try await recipientSocketSend(helloFrame(), on: socket)
            let frame = try await receiveFrame(on: socket, step: "actual host advertisement")
            guard case .control(.hello(let hello)) = frame.payload else {
                Issue.record("expected listener hello")
                await rig.finish()
                return
            }
            #expect(hello.capabilities.contains(DeviceVoiceStop.capability) == wired)
            try await barrier(on: socket, step: "advertisement complete")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func repeatedAcceptedStopsSendOneStopAndCoalesceTheirLog() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: 42)
            #expect(try await receiveFrame(
                on: rig.socket, step: "first accepted stop"
            ).payload == .control(.stopPlayback))
            for _ in 0..<5 { await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: 42) }
            #expect(rig.details("ambient_dismissed").count == 1)
            #expect(rig.details("ambient_voice_stop_ignored") == ["reason=coalesced"])
            try await barrier(on: rig.socket, step: "coalesced stops send no second stop")
            rig.advance(by: 10)
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: 42)
            #expect(try await receiveFrame(
                on: rig.socket, step: "later accepted stop"
            ).payload == .control(.stopPlayback))
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: 42)
            #expect(rig.details("ambient_voice_stop_ignored") == ["reason=coalesced", "reason=coalesced suppressed=4"])
            #expect(rig.details("ambient_dismissed").count == 2)
            try await barrier(on: rig.socket, step: "later coalesced stop sends no frame")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func ignoredReasonsAreCoalescedIndependentlyAndResetAtTenSeconds() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            rig.env.router.state.withLock { $0.reloading = true }
            for _ in 0..<4 { await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil) }
            rig.env.router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
            for _ in 0..<3 { await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil) }
            #expect(rig.details("ambient_voice_stop_ignored") == ["reason=no_active_stream", "reason=private"])
            rig.advance(by: 9)
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            #expect(rig.details("ambient_voice_stop_ignored").count == 2)
            rig.advance(by: 1)
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            rig.env.router.state.withLock { $0.duck[connection] = nil; $0.reloading = false }
            #expect(rig.details("ambient_voice_stop_ignored") == [
                "reason=no_active_stream", "reason=private", "reason=private suppressed=3"
            ])
            try await barrier(on: rig.socket, step: "ignored report burst sends no frames")
            #expect(rig.details("ambient_dismissed").isEmpty)
        } catch {
            rig.env.router.state.withLock { $0.reloading = false }
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
#endif
