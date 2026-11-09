#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientGapFillTests {
    @Test(arguments: [[0, 2], [0, 2, 5, 6], [0, 1, 2], [0, 31], [0, 32], [0, 32, 33], [0, Int.max]])
    func orderedPCMAndTokenOnlyCounts(_ sequences: [Int]) async throws {
        // The default 64 KiB child backlog must also admit a full capped fill atomically.
        let rig = try await AmbientGapFillRig.make(backlogBytes: 65_536)
        do {
            let stream = UUID()
            try await rig.send(stream, try #require(sequences.first))
            let session = try #require(rig.env.router.activePipeline?.session)
            var expected = AmbientGapFillRig.chunk(sequences[0])
            var fills = 0, totalMissing = 0, totalMS = 0, capped = 0
            for (last, sequence) in zip(sequences, sequences.dropFirst()) {
                let missing = sequence - last - 1
                rig.clock.advance(.milliseconds((min(missing, 30) + 1) * 100))
                if missing > 0 {
                    expected.append(AmbientGapFillRig.silence(missing))
                    fills += 1; totalMissing += missing; totalMS += min(missing, 30) * 100
                    if missing > 30 { capped += 1 }
                }
                expected.append(AmbientGapFillRig.chunk(sequence))
                try await rig.send(stream, sequence, final: sequence == sequences.last)
            }
            await rig.env.router.settle() // EOF and child task completion acknowledge every stdin byte.
            #expect(try rig.heard(session) == expected)
            let details = fills == 0 ? [] : [
                "fills=\(fills) missing=\(totalMissing) filled_ms=\(totalMS) capped=\(capped)"
            ]
            #expect(rig.fills.map(\.detail) == details.map(Optional.some))
            #expect(rig.fills.allSatisfy { $0.sessionID == nil && $0.endpoint == nil })
            // A segment after final is refused: it cannot synthesize a trailing gap.
            #expect(await rig.env.gate.admit(AmbientGapFillRig.segment(stream, Int.max),
                        connection: rig.connection, target: RecipientTestRig.target) != nil)
            #expect(try rig.heard(session) == expected)
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test func newStreamStartsFreshAfterAGap() async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let first = UUID(), second = UUID()
            try await rig.send(first, 0)
            let firstSession = try #require(rig.env.router.activePipeline?.session)
            rig.clock.advance(.seconds(1))
            try await rig.send(first, 4, final: true)
            await rig.env.router.settle()
            try await rig.send(second, 0)
            let secondSession = try #require(rig.env.router.activePipeline?.session)
            try await rig.send(second, 1, final: true)
            await rig.env.router.settle()
            #expect(try rig.heard(firstSession) == AmbientGapFillRig.chunk(0)
                    + AmbientGapFillRig.silence(3) + AmbientGapFillRig.chunk(4))
            #expect(try rig.heard(secondSession) == AmbientGapFillRig.chunk(0) + AmbientGapFillRig.chunk(1))
            #expect(rig.fills.count == 1)
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test(arguments: [false, true])
    func privacySuppressionWritesNeitherPCMNorSilenceAndResumeIsCapped(_ suppressFirst: Bool) async throws {
        // Hold the child's started proof until EOF: privacy cannot become confirmed during the suppression.
        let fake = try FakeRightyo("""
        /bin/cat > audio.raw
        /usr/bin/sed -n -e '1p' -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let clock = AmbientGapTestClock()
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: false, gapClock: { clock.now })
        if !suppressFirst { #expect(pipeline.send(audio: AmbientGapFillRig.chunk(0), sequence: 0).accepted) }
        #expect(pipeline.reportDuck(true))
        #expect(!pipeline.hearsAudio && !pipeline.childStarted)
        for sequence in [2, 50, 99] {
            let result = pipeline.send(audio: AmbientGapFillRig.chunk(sequence), sequence: sequence)
            #expect(result.accepted && result.gap == nil)
        }
        clock.advance(.seconds(4))
        _ = pipeline.reportDuck(false)
        let resumed = pipeline.send(audio: AmbientGapFillRig.chunk(100), sequence: 100)
        #expect(resumed.accepted)
        #expect(resumed.gap?.detail == (suppressFirst ? nil : "missing=99 filled_ms=3000 capped=true"))
        pipeline.finishInput()
        let summary = try await pipeline.run()
        #expect(summary.child.droppedBytes == 0)
        let before = suppressFirst ? Data() : AmbientGapFillRig.chunk(0) + AmbientGapFillRig.silence(99)
        #expect(try Data(contentsOf: fake.directory.appendingPathComponent("audio.raw"))
                == before + AmbientGapFillRig.chunk(100))
    }

    @Test func confirmedPrivateExitAudioDoesNotSynthesizeSilence() async throws {
        let fake = try FakeRightyo("""
        \(AmbientPrivacyEntryTests.startPrivatePrelude)
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"\(FakeRightyo.duckV3)
        /bin/cat > audio.raw
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let pipeline = try AmbientPrivacyAudioGateTests.pipeline(fake, startPrivate: true)
        let run = Task { try await pipeline.run() }
        do {
            // Acknowledged started-private proof, rather than a sleep or a file-size observation.
            try #require(await pipeline.privacyKept())
            for sequence in [0, 99] {
                let result = pipeline.send(audio: AmbientGapFillRig.chunk(sequence), sequence: sequence)
                #expect(result.accepted && result.gap == nil)
            }
            pipeline.finishInput()
            let summary = try await run.value
            #expect(summary.child.droppedBytes == 0)
            #expect(try Data(contentsOf: fake.directory.appendingPathComponent("audio.raw"))
                    == AmbientGapFillRig.chunk(0) + AmbientGapFillRig.chunk(99))
        } catch {
            await pipeline.stop(grace: 0)
            _ = try? await run.value
            throw error
        }
    }
}
#endif
