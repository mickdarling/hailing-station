#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension AmbientGapFillTests {
    @Test func duplicateAndReorderDoNotRegressOrWedgePipelineSequence() async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let stream = UUID()
            try await rig.send(stream, 0)
            let pipeline = try #require(rig.env.router.activePipeline)
            rig.clock.advance(.seconds(2))
            #expect(pipeline.send(audio: AmbientGapFillRig.chunk(5), sequence: 5).gap?.missing == 4)
            for sequence in [5, 3, 6] {
                let result = pipeline.send(audio: AmbientGapFillRig.chunk(sequence), sequence: sequence)
                #expect(result.accepted && result.gap == nil)
            }
            #expect(pipeline.send(audio: AmbientGapFillRig.chunk(8), sequence: 8).gap?.missing == 1)
            pipeline.finishInput()
            await rig.env.router.settle()
            var expected = AmbientGapFillRig.chunk(0) + AmbientGapFillRig.silence(4)
            for sequence in [5, 5, 3, 6] { expected.append(AmbientGapFillRig.chunk(sequence)) }
            expected.append(AmbientGapFillRig.silence(1) + AmbientGapFillRig.chunk(8))
            #expect(try rig.heard(pipeline.session) == expected)
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test func refusedWriteDoesNotAdvanceSequenceOrConsumeBudget() async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let stream = UUID()
            try await rig.send(stream, 0)
            let pipeline = try #require(rig.env.router.activePipeline)
            rig.clock.advance(.seconds(1))
            #expect(!pipeline.send(audio: Data([1]), sequence: 99).accepted)
            let accepted = pipeline.send(audio: AmbientGapFillRig.chunk(2), sequence: 2)
            #expect(accepted.accepted && accepted.gap?.missing == 1 && accepted.gap?.bytes == 3_200)
            pipeline.finishInput()
            await rig.env.router.settle()
            #expect(try rig.heard(pipeline.session) == AmbientGapFillRig.joined(
                AmbientGapFillRig.chunk(0), AmbientGapFillRig.silence(1), AmbientGapFillRig.chunk(2)))
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test func reloadStartsFreshAcrossAnOpenHole() async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let stream = UUID()
            try await rig.send(stream, 0)
            let old = try #require(rig.env.router.activePipeline)
            rig.clock.advance(.seconds(4))
            #expect(await rig.env.router.reload() == .reloaded)
            let replacement = try #require(rig.env.router.activePipeline)
            #expect(old !== replacement)
            try await rig.send(stream, 50, final: true)
            await rig.env.router.settle()
            #expect(try rig.heard(old.session) == AmbientGapFillRig.chunk(0))
            #expect(try rig.heard(replacement.session) == AmbientGapFillRig.chunk(50))
            #expect(rig.fills.isEmpty)
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test func gateNonIncreasingRejectionProducesNoFill() async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let stream = UUID()
            try await rig.send(stream, 0)
            let session = try #require(rig.env.router.activePipeline?.session)
            rig.clock.advance(.seconds(4))
            let refusal = await rig.env.gate.admit(AmbientGapFillRig.segment(stream, 0),
                                                   connection: rig.connection, target: RecipientTestRig.target)
            #expect(refusal == .malformed)
            await rig.env.router.settle()
            #expect(try rig.heard(session) == AmbientGapFillRig.chunk(0))
            #expect(rig.fills.isEmpty)
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
}
#endif
