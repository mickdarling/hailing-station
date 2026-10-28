#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct ModeSnapshotPipelineTests {
    @Test(arguments: 0..<8)
    func pipelinedSelectStartAndAudioWaitForTheEntireSnapshot(attempt: Int) async throws {
        let rig = try await ModeSnapshotPipelineRig()
        do {
            let client = try await rig.connect()
            defer { client.cancel() }
            rig.order.arm()
            let stream = UUID()
            let frames = [helloFrame(capabilities: [ModeSnapshot.capability]),
                          sessionFrame(payload: .control(.select(targetID: "tmux:a"))),
                          sessionFrame(target: "tmux:a", payload: .audio(ambientSegment(stream: stream, sequence: 0))),
                          sessionFrame(target: "tmux:a", payload: .audio(ambientSegment(
                            stream: stream, sequence: 1, isFinal: true)))]
            // Client send completions only: no response is read while the entire pipeline is queued.
            for frame in frames { try await client.send(frame) }
            try #require(await eventually { rig.hello.arrivals.count == 1 })
            #expect(rig.order.observed.isEmpty)
            await rig.hello.releaseAll()
            try await snapshot(on: client)
            #expect(await eventually { rig.order.observed.filter { $0 == "pcm" }.count == 2 }, "both PCM segments")
            #expect(rig.order.observed.filter { $0 == "started" }.count == 1)
            #expect(rig.order.observed.filter { $0 == "audio_frame" }.count == 2)
            #expect(rig.order.early.isEmpty, "attempt \(attempt): no select, start or PCM before all snapshot sends")
        } catch {
            await rig.close()
            throw error
        }
        await rig.close()
    }

    private func snapshot(on client: SilentPeer) async throws {
        guard case .control(.hello) = try await client.receive().payload else {
            throw TestSupportError.expectedOneControl
        }
        #expect(try await client.receive().payload == .control(.duckMode(on: false)))
        #expect(try await client.receive().payload == .control(.mediaMode(on: false)))
    }
}
#endif
