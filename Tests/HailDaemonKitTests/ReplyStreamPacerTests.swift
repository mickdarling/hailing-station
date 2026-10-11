import Foundation
import Testing
@testable import HailDaemonKit

/// #430 slice 2: a long spoken reply is paced to play in full, under the endpoint's frame limit, with a bounded lead.
@Suite struct ReplyStreamPacerTests {
    private static let frame = 1.25 // seconds of audio in a full streamed frame

    @Test func aReplyLongerThanTheOldBudgetIsAdmittedInFullWithinTheRateAndLead() throws {
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        var sends: [ContinuousClock.Instant] = []
        var audioBefore = 0.0
        // Ten minutes of speech, rendered instantly: far past the old ~146 s.
        for _ in 0..<480 {
            let sendAt = try pacer.admit(audio: Self.frame, at: start)
            #expect(sendAt >= start.advanced(by: .seconds(max(0, audioBefore - ReplyStreamPacer.leadSeconds))))
            sends.append(sendAt)
            audioBefore += Self.frame
        }
        for (index, sent) in sends.enumerated() {
            let window = sends[index...].prefix { $0 < sent.advanced(by: .seconds(60)) }
            #expect(window.count <= ReplyStreamPacer.framesPerMinute)
        }
        #expect(ReplyStreamPacer.framesPerMinute < LocalReplyEndpoint.maxFramesPerMinute)
        // Paced to real time: the last frame leaves about when its audio starts, less the lead.
        let last = try #require(sends.last)
        #expect(start.duration(to: last) >= .seconds(600 - ReplyStreamPacer.leadSeconds - 2 * Self.frame))
    }

    @Test func textAndMarkersCountTowardTheRate() throws {
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        for _ in 0..<ReplyStreamPacer.framesPerMinute { #expect(try pacer.admit(audio: 0, at: start) == start) }
        #expect(try pacer.admit(audio: 0, at: start) == start.advanced(by: .seconds(60)))
    }

    @Test func theAudioBoundRefusesWithoutAdmitting() throws {
        var pacer = ReplyStreamPacer(paced: false)
        let now = ContinuousClock.now
        _ = try pacer.admit(audio: ReplyStreamPacer.maxAudioSeconds - 1, at: now)
        #expect(throws: ReplyStreamPacerError.audioBoundExceeded) { try pacer.admit(audio: 2, at: now) }
        #expect(try pacer.admit(audio: 1, at: now) == now)
        #expect(throws: ReplyStreamPacerError.audioBoundExceeded) { try pacer.admit(audio: 0.01, at: now) }
    }

    @Test func unpacedFramesGoAtOnce() throws {
        var pacer = ReplyStreamPacer(paced: false)
        let now = ContinuousClock.now
        for _ in 0..<500 { #expect(try pacer.admit(audio: Self.frame, at: now) == now) }
    }

    @Test func aCancelledReplyStopsWaiting() async throws {
        let pacing = ReplyStreamPacing()
        try await pacing.admit(audio: 600) // the first frame never waits
        let next = Task { try await pacing.admit(audio: Self.frame) } // 580 s ahead of real time: waits
        next.cancel()
        await #expect(throws: CancellationError.self) { try await next.value }
    }

    @Test func theRendererGateHoldsTheReaderAndCloseReleasesIt() async {
        let gate = RendererOutputGate()
        gate.add(RendererOutputGate.limit)
        let blocked = Task.detached { gate.waitForRoom() }
        gate.take(1)
        #expect(await blocked.value)
        gate.add(1)
        let closed = Task.detached { gate.waitForRoom() }
        gate.close()
        #expect(!(await closed.value))
    }
}
