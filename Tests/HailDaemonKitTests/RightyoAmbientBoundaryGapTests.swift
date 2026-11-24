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
            #expect(pipeline.withhold(sequence: 1, byteCount: Self.fragment.count).accepted)
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

    @Test func withheldFragmentPreservesPrecedingHoleSilence() async throws {
        let first = AmbientGapFillRig.chunk(0), next = AmbientGapFillRig.chunk(3)
        func captureHole(withhold: Bool) async throws -> (heard: Data, gap: AmbientGapFill?) {
            var gap: AmbientGapFill?
            let heard = try await capture { pipeline, clock in
                #expect(pipeline.send(audio: first, sequence: 0).accepted)
                clock.advance(.milliseconds(300))
                let fragment = Self.submitFragment(to: pipeline, sequence: 2, withhold: withhold)
                #expect(fragment.accepted)
                gap = fragment.gap
                let result = pipeline.send(audio: next, sequence: 3)
                #expect(result.accepted && result.gap == nil)
            }
            return (heard, gap)
        }
        let forwarded = try await captureHole(withhold: false)
        let prefixBytes = forwarded.heard.count - first.count - Self.fragment.count - next.count
        try #require(prefixBytes > 0)
        let silence = Data(repeating: 0, count: prefixBytes)
        #expect(forwarded.heard == AmbientGapFillRig.joined(first, silence, Self.fragment, next))
        let withheld = try await captureHole(withhold: true)
        #expect(withheld.gap == forwarded.gap && withheld.gap?.bytes == prefixBytes)
        #expect(withheld.heard == AmbientGapFillRig.joined(first, silence, next))
    }

    /// The probe has 199.9375 ms of credit. Another 62,500 ns buys the second 100 ms slice.
    @Test(arguments: [false, true], [0, 62_500])
    func suppressionAndRemainingBudgetMatchForwarding(_ withhold: Bool, extraNanoseconds: Int) async throws {
        let first = AmbientGapFillRig.chunk(0), resumed = AmbientGapFillRig.chunk(2), last = AmbientGapFillRig.chunk(7)
        let silence = AmbientGapFillRig.silence(1)
        let expectedProbeBytes = extraNanoseconds == 0 ? 3_200 : 6_400
        let heard = try await capture { pipeline, clock in
            #expect(pipeline.send(audio: first, sequence: 0).accepted)
            clock.advance(.milliseconds(300))
            #expect(pipeline.reportDuck(true))
            #expect(!pipeline.hearsAudio)
            #expect(Self.submitFragment(to: pipeline, sequence: 1, withhold: withhold).accepted)
            #expect(!pipeline.hearsAudio)
            #expect(pipeline.reportDuck(false))
            let resume = pipeline.send(audio: resumed, sequence: 2)
            #expect(resume.accepted && resume.gap?.bytes == 3_200)

            clock.advance(.milliseconds(100))
            #expect(Self.submitFragment(to: pipeline, sequence: 4, withhold: withhold).accepted)
            clock.advance(.milliseconds(200) + .nanoseconds(extraNanoseconds))
            let probe = pipeline.send(audio: last, sequence: 7)
            #expect(probe.accepted && probe.gap?.missing == 2 && probe.gap?.bytes == expectedProbeBytes)
        }
        var expected = AmbientGapFillRig.joined(first, silence, resumed, silence)
        if !withhold { expected.append(Self.fragment) }
        expected.append(Data(repeating: 0, count: expectedProbeBytes) + last)
        #expect(heard == expected)
    }

    private static func submitFragment(to pipeline: RightyoAmbientPipeline, sequence: Int, withhold: Bool)
        -> (accepted: Bool, gap: AmbientGapFill?) {
        if withhold { return pipeline.withhold(sequence: sequence, byteCount: fragment.count) }
        return pipeline.send(audio: fragment, sequence: sequence)
    }

    @Test func writerRefusalDoesNotConsumeASequence() async throws {
        let first = AmbientGapFillRig.chunk(0), next = AmbientGapFillRig.chunk(2)
        let heard = try await capture { pipeline, clock in
            #expect(pipeline.send(audio: first, sequence: 0).accepted)
            clock.advance(.milliseconds(300))
            for byteCount in [-2, 0, 1, 65_538] {
                #expect(!pipeline.withhold(sequence: 1, byteCount: byteCount).accepted)
            }
            let result = pipeline.send(audio: next, sequence: 2)
            #expect(result.accepted && result.gap?.bytes == 3_200)
            pipeline.finishInput()
            #expect(!pipeline.withhold(sequence: 3, byteCount: Self.fragment.count).accepted)
        }
        #expect(heard == AmbientGapFillRig.joined(first, AmbientGapFillRig.silence(1), next))
    }
}
#endif
