#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension AmbientGapFillTests {
    @Test(arguments: ["suppression", "idle", "slow"])
    func longUnchargedTimeCannotAccumulateMoreThanThreeSeconds(_ mode: String) async throws {
        let rig = try await AmbientGapFillRig.make(holdStarted: true)
        do {
            let pair = try await Self.bucketInput(rig)
            defer { pair.close() }
            let pipeline = try #require(rig.env.router.activePipeline)
            if mode == "suppression" {
                try await Self.bucketPrivacy(true, on: pair.sockets[0])
                #expect(!pipeline.hearsAudio && !pipeline.childStarted)
            }
            for index in 1...60 {
                if mode != "idle" {
                    let result = pipeline.send(audio: Data([1, 2]), sequence: index)
                    #expect(result.accepted && result.gap == nil)
                }
                rig.clock.advance(.seconds(10)) // Ten minutes, without waiting or expiring the gate.
            }
            if mode == "suppression" { try await Self.bucketPrivacy(false, on: pair.sockets[0]) }
            let first = Self.flood(pipeline, startingAt: 100)
            #expect(first.slices == 30)
            rig.clock.advance(.seconds(1))
            let second = Self.flood(pipeline, startingAt: 10_000)
            #expect(second.slices == 9) // 400 tiny PCM bytes also spend 12.5 ms from the first bucket.
            #expect(second.slices <= 10)
            pipeline.finishInput()
            await rig.env.router.settle()
            let slowPCM = mode == "slow" ? Data((0..<120).map { $0.isMultiple(of: 2) ? UInt8(1) : 2 }) : Data()
            #expect(try rig.heard(pipeline.session) == AmbientGapFillRig.joined(
                AmbientGapFillRig.chunk(0), slowPCM, first.bytes, second.bytes))
            #expect(pipeline.counters.writtenBytes == 4_000 + slowPCM.count)
            #expect(pipeline.counters.droppedBytes == 0)
        } catch { await rig.finish(); throw error }
        await rig.finish()
    }

    private static func bucketInput(_ rig: AmbientGapFillRig) async throws -> FallbackSocketPair {
        let pair = try await FallbackSocketPair.boundedConnect(port: rig.env.port,
                                                               selecting: [RecipientTestRig.target])
        do {
            try await recipientSocketSend(sessionFrame(target: RecipientTestRig.target,
                payload: .audio(AmbientGapFillRig.segment(UUID(), 0))), on: pair.sockets[0])
            _ = try await AmbientPrivacySwitchTests.untilPong(pair.sockets[0], step: "initial bucket PCM")
            return pair
        } catch { pair.close(); throw error }
    }

    private static func bucketPrivacy(_ on: Bool, on socket: URLSessionWebSocketTask) async throws {
        try await AmbientPrivacySwitchTests.send(on, on: socket)
        _ = try await AmbientPrivacySwitchTests.untilPong(socket, step: "bucket privacy handled")
    }

    private static func flood(_ pipeline: RightyoAmbientPipeline, startingAt start: Int) -> (slices: Int, bytes: Data) {
        var slices = 0, bytes = Data()
        for index in 0..<200 {
            let result = pipeline.send(audio: Data([1, 2]), sequence: start + index * 32)
            #expect(result.accepted)
            slices += result.gap?.segments ?? 0
            bytes.append(AmbientGapFillRig.silence(result.gap?.segments ?? 0))
            bytes.append(contentsOf: [1, 2])
        }
        return (slices, bytes)
    }
}
#endif
