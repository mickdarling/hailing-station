#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension AmbientGapFillTests {
    @Test(arguments: [1_500, 4_100])
    func listenerPrivacyDuringHoleWritesNothingAndResumeHasBothBounds(_ milliseconds: Int) async throws {
        let rig = try await AmbientGapFillRig.make(holdStarted: true)
        do {
            let pair = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                                                                   selecting: [RecipientTestRig.target])
            defer { pair.close() }
            let socket = pair.sockets[0], stream = UUID()
            try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                payload: .audio(AmbientGapFillRig.segment(stream, 0))), on: socket)
            _ = try await AmbientPrivacySwitchTests.untilPong(socket, step: "initial PCM admitted")
            let pipeline = try #require(rig.env.router.activePipeline)
            #expect(await eventually { pipeline.counters.writtenBytes == 3_200 })
            // A hole is now open. Privacy arrives through the listener before its next segment.
            rig.clock.advance(.milliseconds(milliseconds))
            try await AmbientPrivacySwitchTests.send(true, on: socket)
            _ = try await AmbientPrivacySwitchTests.untilPong(socket, step: "privacy wish handled")
            #expect(!pipeline.hearsAudio && !pipeline.childStarted)
            for sequence in [2, 20, 49] {
                try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                    payload: .audio(AmbientGapFillRig.segment(stream, sequence))), on: socket)
            }
            _ = try await AmbientPrivacySwitchTests.untilPong(socket, step: "suppressed segments handled")
            #expect(pipeline.counters.writtenBytes == 3_200)
            #expect(rig.fills.isEmpty)
            try await AmbientPrivacySwitchTests.send(false, on: socket)
            _ = try await AmbientPrivacySwitchTests.untilPong(socket, step: "privacy withdrawn")
            #expect(pipeline.hearsAudio)
            try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                payload: .audio(AmbientGapFillRig.segment(stream, 50, final: true))), on: socket)
            _ = try await AmbientPrivacySwitchTests.untilPong(socket, step: "final resumed segment")
            await rig.env.router.settle()
            let slices = milliseconds == 1_500 ? 14 : 30
            #expect(try rig.heard(pipeline.session) == AmbientGapFillRig.chunk(0)
                    + AmbientGapFillRig.silence(slices) + AmbientGapFillRig.chunk(50))
            #expect(pipeline.counters.writtenBytes == 6_400 && pipeline.counters.droppedBytes == 0)
            #expect(rig.fills.map(\.detail) == ["fills=1 missing=49 filled_ms=\(slices * 100) capped=1"])
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
}
#endif
