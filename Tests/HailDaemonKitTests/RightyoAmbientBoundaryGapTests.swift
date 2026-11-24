#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct RightyoAmbientBoundaryGapTests {
    private static let fragment = Data([0xD1, 0xD2])

    private func capture(_ exercise: (RightyoAmbientPipeline, AmbientGapTestClock) -> Void) async throws -> Data {
        let fake = try AmbientPrivacyAudioGateTests.fake("""
        /bin/cat > audio.raw
        /usr/bin/sed -n -e '1p' -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        let clock = AmbientGapTestClock()
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: false, gapClock: { clock.now })
        exercise(pipeline, clock)
        pipeline.finishInput()
        let summary = try await pipeline.run()
        #expect(summary.child.droppedBytes == 0)
        return try Data(contentsOf: fake.directory.appendingPathComponent("audio.raw"))
    }

    @Test func withheldFragmentLeavesPublicChunksAdjacent() async throws {
        let first = AmbientGapFillRig.chunk(0), next = AmbientGapFillRig.chunk(2)
        let heard = try await capture { pipeline, clock in
            #expect(pipeline.send(audio: first, sequence: 0).accepted)
            #expect(pipeline.reportDuck(true))
            clock.advance(.milliseconds(300))
            #expect(pipeline.reportDuck(false))
            #expect(pipeline.withhold(sequence: 1, byteCount: Self.fragment.count))
            let result = pipeline.send(audio: next, sequence: 2)
            #expect(result.accepted && result.gap == nil)
        }
        #expect(heard == first + next)
    }

    @Test func genuineHoleStillPrefixesOneSilenceChunk() async throws {
        let first = AmbientGapFillRig.chunk(0), next = AmbientGapFillRig.chunk(2)
        let heard = try await capture { pipeline, clock in
            #expect(pipeline.send(audio: first, sequence: 0).accepted)
            clock.advance(.milliseconds(300))
            let result = pipeline.send(audio: next, sequence: 2)
            #expect(result.accepted && result.gap?.bytes == 3_200)
        }
        #expect(heard == AmbientGapFillRig.joined(first, AmbientGapFillRig.silence(1), next))
    }

    /// Charging the fragment and its prefix leaves 199.9375 ms for the last probe, enough for one whole slice.
    @Test(arguments: [false, true])
    func suppressionAndRemainingBudgetMatchForwarding(_ withhold: Bool) async throws {
        let first = AmbientGapFillRig.chunk(0), resumed = AmbientGapFillRig.chunk(2), last = AmbientGapFillRig.chunk(7)
        let silence = AmbientGapFillRig.silence(1)
        let heard = try await capture { pipeline, clock in
            #expect(pipeline.send(audio: first, sequence: 0).accepted)
            clock.advance(.milliseconds(300))
            #expect(pipeline.reportDuck(true))
            #expect(!pipeline.hearsAudio)
            #expect(Self.submitFragment(to: pipeline, sequence: 1, withhold: withhold))
            #expect(!pipeline.hearsAudio)
            #expect(pipeline.reportDuck(false))
            let resume = pipeline.send(audio: resumed, sequence: 2)
            #expect(resume.accepted && resume.gap?.bytes == 3_200)

            clock.advance(.milliseconds(100))
            #expect(Self.submitFragment(to: pipeline, sequence: 4, withhold: withhold))
            clock.advance(.milliseconds(200))
            let probe = pipeline.send(audio: last, sequence: 7)
            #expect(probe.accepted && probe.gap?.missing == 2 && probe.gap?.bytes == 3_200)
        }
        var expected = AmbientGapFillRig.joined(first, silence, resumed)
        if !withhold { expected.append(silence + Self.fragment) }
        expected.append(silence + last)
        #expect(heard == expected)
    }

    private static func submitFragment(to pipeline: RightyoAmbientPipeline, sequence: Int, withhold: Bool) -> Bool {
        if withhold { return pipeline.withhold(sequence: sequence, byteCount: fragment.count) }
        return pipeline.send(audio: fragment, sequence: sequence).accepted
    }

    @Test func writerRefusalDoesNotConsumeASequence() async throws {
        let first = AmbientGapFillRig.chunk(0), next = AmbientGapFillRig.chunk(2)
        let heard = try await capture { pipeline, clock in
            #expect(pipeline.send(audio: first, sequence: 0).accepted)
            clock.advance(.milliseconds(300))
            for byteCount in [-2, 0, 1, 65_538] {
                #expect(!pipeline.withhold(sequence: 1, byteCount: byteCount))
            }
            let result = pipeline.send(audio: next, sequence: 2)
            #expect(result.accepted && result.gap?.bytes == 3_200)
            pipeline.finishInput()
            #expect(!pipeline.withhold(sequence: 3, byteCount: Self.fragment.count))
        }
        #expect(heard == AmbientGapFillRig.joined(first, AmbientGapFillRig.silence(1), next))
    }
}
#endif
