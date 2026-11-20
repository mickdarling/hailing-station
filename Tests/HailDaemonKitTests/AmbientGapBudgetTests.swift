#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension AmbientGapFillTests {
    @Test(arguments: [0, 1]) func tinyJumpFloodHasCumulativeBudgetAndBoundedLogs(_ milliseconds: Int) async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let stream = UUID()
            var expectedReal = Data()
            var session: String?
            for index in 0..<1_000 {
                if index > 0 { rig.clock.advance(.milliseconds(milliseconds)) }
                var segment = AmbientGapFillRig.segment(stream, index * 32, final: index == 999)
                segment.bytes = Data([1, 2])
                expectedReal.append(segment.bytes)
                #expect(await rig.env.gate.admit(segment, connection: rig.connection,
                                                  target: RecipientTestRig.target) == nil)
                if index == 0 { session = rig.env.router.activePipeline?.session }
            }
            let recordedSession = try #require(session)
            await rig.env.router.settle()
            let bytes = try rig.heard(recordedSession)
            let silence = bytes.filter { $0 == 0 }.count
            #expect(bytes.filter { $0 != 0 } == expectedReal)
            #expect(silence <= (milliseconds == 0 ? 0 : 9 * 3_200))
            #expect(rig.fills.count <= (milliseconds == 0 ? 0 : 1))
            #expect(rig.fills.map(\.detail) == (milliseconds == 0 ? [] : [
                "fills=9 missing=279 filled_ms=900 capped=9"
            ]))
            #expect(await rig.env.gate.overRateDropped == 0)
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test(arguments: [1_000, 1_100]) func realOutageFillsOnlyElapsedUnwrittenTime(_ milliseconds: Int) async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let stream = UUID()
            try await rig.send(stream, 0)
            let session = try #require(rig.env.router.activePipeline?.session)
            rig.clock.advance(.milliseconds(milliseconds))
            try await rig.send(stream, 11, final: true)
            await rig.env.router.settle()
            let slices = milliseconds == 1_000 ? 9 : 10
            #expect(try rig.heard(session) == AmbientGapFillRig.joined(
                AmbientGapFillRig.chunk(0), AmbientGapFillRig.silence(slices), AmbientGapFillRig.chunk(11)))
            #expect(rig.fills.map(\.detail) == [
                "fills=1 missing=10 filled_ms=\(slices * 100) capped=\(slices == 10 ? 0 : 1)"
            ])
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test(arguments: [350, 650]) func burstAheadOfClockCannotBuySilence(_ milliseconds: Int) async throws {
        let rig = try await AmbientGapFillRig.make()
        do {
            let stream = UUID()
            try await rig.send(stream, 0)
            let session = try #require(rig.env.router.activePipeline?.session)
            var expected = AmbientGapFillRig.chunk(0)
            for sequence in 1...3 {
                try await rig.send(stream, sequence)
                expected.append(AmbientGapFillRig.chunk(sequence))
            }
            rig.clock.advance(.milliseconds(milliseconds))
            try await rig.send(stream, 14, final: true)
            await rig.env.router.settle()
            expected.append(AmbientGapFillRig.silence(milliseconds == 350 ? 0 : 2))
            expected.append(AmbientGapFillRig.chunk(14))
            #expect(try rig.heard(session) == expected)
            #expect(rig.fills.count == (milliseconds == 350 ? 0 : 1))
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    @Test func overRateDropCannotBuySilenceAfterABurst() async throws {
        let rig = try await AmbientGapFillRig.make(backlogBytes: 524_288)
        do {
            let stream = UUID()
            for sequence in 0..<130 { try await rig.send(stream, sequence) }
            let session = try #require(rig.env.router.activePipeline?.session)
            // 128 * 3,200 exactly exhausts the gate's 409,600-byte burst; two segments were dropped.
            #expect(await rig.env.gate.overRateDropped == 2)
            rig.clock.advance(.milliseconds(100))
            try await rig.send(stream, 130, final: true)
            await rig.env.router.settle()
            var expected = Data()
            for sequence in 0..<128 { expected.append(AmbientGapFillRig.chunk(sequence)) }
            expected.append(AmbientGapFillRig.chunk(130))
            #expect(try rig.heard(session) == expected)
            #expect(rig.fills.isEmpty) // 12.8 s of real PCM already committed against only 0.1 s elapsed.
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }
}
#endif
