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

    @Test(arguments: [16_000, 24_000, 32_000, 44_100, 48_000])
    func aFileExactlyAtTheBoundIsAdmittedSegmentBySegment(sampleRate: Int) throws {
        var pacer = ReplyStreamPacer(paced: false)
        let now = ContinuousClock.now
        var remaining = sampleRate * 2 * Int(ReplyStreamPacer.maxAudioSeconds)
        while remaining > 0 {
            let segment = min(remaining, 48 * 1_024)
            _ = try pacer.admit(audio: ReplyStreamPacer.seconds(pcm16Bytes: segment, sampleRate: sampleRate), at: now)
            remaining -= segment
        }
        #expect(throws: ReplyStreamPacerError.audioBoundExceeded) {
            try pacer.admit(audio: ReplyStreamPacer.seconds(pcm16Bytes: 2, sampleRate: sampleRate), at: now)
        }
    }

    @Test func aRequestBoundLatestCapsEveryWait() throws {
        // #467: the rate rule would hold frame 101 for a minute; a request-bound frame goes by its `latest` instead.
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        for _ in 0..<ReplyStreamPacer.framesPerMinute { _ = try pacer.admit(audio: 0, at: start) }
        let latest = start.advanced(by: .seconds(40))
        #expect(try pacer.admit(audio: 0, at: start, latest: latest) == latest)
        // A `latest` already past still never schedules a frame before now.
        let later = start.advanced(by: .seconds(5))
        #expect(try pacer.admit(audio: 0, at: later, latest: start) == later)
    }

    @Test func aRequestBoundLatestAlsoCapsTheAudioLeadWait() throws {
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        _ = try pacer.admit(audio: 60, at: start)
        // #467: even the audio lead rule yields to the CLI's 40 s data budget, inside the host's 60 s idle gap.
        let latest = start.advanced(by: .seconds(40))
        #expect(try pacer.admit(audio: Self.frame, at: start, latest: latest) == latest)
    }

    @Test func unpacedFramesGoAtOnce() throws {
        var pacer = ReplyStreamPacer(paced: false)
        let now = ContinuousClock.now
        for _ in 0..<500 { #expect(try pacer.admit(audio: Self.frame, at: now) == now) }
    }

    @Test func aCancelledReplyStopsWaiting() async throws {
        let pacing = ReplyStreamPacing()
        try await pacing.admit(audio: 600) // the first frame never waits
        let next = Task { try await pacing.admit(audio: Self.frame) } // Far ahead of real time: waits
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
