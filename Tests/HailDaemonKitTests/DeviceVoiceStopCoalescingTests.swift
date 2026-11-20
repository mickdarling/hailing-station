#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct DeviceVoiceStopCoalescingTests {
    @Test(arguments: ["streaming", "completed", "final_only"])
    func audioSinceTheAcceptedStopRequiresAnotherStop(kind: String) async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            #expect(try await receiveFrame(on: rig.socket, step: "initial stop").payload == .control(.stopPlayback))
            rig.observation.clock.withLock { $0 = $0.advanced(by: .milliseconds(200)) }
            let reply = uncorrelatedDescriptor(audio: true)
            let first = recipientAudio(reply, sequence: 0, final: kind == "final_only")
            #expect(try await rig.env.listener.publish(first) == 1)
            #expect(try await receiveFrame(on: rig.socket, step: "new reply starts") == first)
            if kind == "completed" {
                let final = recipientAudio(reply, sequence: 1, final: true)
                #expect(try await rig.env.listener.publish(final) == 1)
                #expect(try await receiveFrame(on: rig.socket, step: "new reply completes") == final)
            }
            rig.observation.clock.withLock { $0 = $0.advanced(by: .milliseconds(300)) }
            await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            #expect(try await receiveFrame(on: rig.socket, step: "new reply stop").payload == .control(.stopPlayback))
            #expect(rig.details("ambient_dismissed").count == 2)
            #expect(rig.details("ambient_voice_stop_ignored").isEmpty)
            if kind == "streaming" {
                await #expect(throws: LocalReplyRefusal.replyStopped) {
                    try await rig.env.listener.publish(recipientAudio(reply, sequence: 1, final: true))
                }
            }
            try await barrier(on: rig.socket, step: "new reply stop complete")
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }

    @Test func coalescedReportsDoNotSlideTheAcceptedStopWindow() async throws {
        let rig = try await DeviceVoiceStopRig.make()
        do {
            try await rig.start()
            let connection = try #require(rig.env.router.activeConnection())
            for index in 0..<6 {
                if index > 0 { rig.observation.clock.withLock { $0 = $0.advanced(by: .milliseconds(900)) } }
                await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
                if index.isMultiple(of: 2) {
                    #expect(try await receiveFrame(
                        on: rig.socket, step: "fixed-window stop"
                    ).payload == .control(.stopPlayback))
                }
                #expect(rig.details("ambient_dismissed").count == index / 2 + 1)
                try await barrier(on: rig.socket, step: "fixed-window report complete")
            }
            #expect(rig.details("ambient_voice_stop_ignored") == ["reason=coalesced"])
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
#endif
