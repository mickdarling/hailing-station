import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct ReplyStreamPacerQueueTests {
    @Test func contentionChangesLeadWithoutResettingTheAudioClock() throws {
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        _ = try pacer.admit(audio: 30, at: start)
        #expect(try pacer.admit(audio: 1, at: start, lead: ReplyStreamPacer.queuedLeadSeconds)
                == start.advanced(by: .seconds(10)))
        // Removing the waiter restores 3 s against ALL audio already admitted, without a fresh clock.
        #expect(try pacer.admit(audio: 1, at: start) == start.advanced(by: .seconds(28)))
    }

    @Test func largerLeadPreservesRateAndLatestCaps() throws {
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        for _ in 0..<ReplyStreamPacer.framesPerMinute {
            _ = try pacer.admit(audio: 0, at: start, lead: ReplyStreamPacer.queuedLeadSeconds)
        }
        #expect(try pacer.admit(audio: 1, at: start, lead: ReplyStreamPacer.queuedLeadSeconds)
                == start.advanced(by: .seconds(60)))
        let latest = start.advanced(by: .seconds(40))
        #expect(try pacer.admit(audio: 1, at: start, latest: latest, lead: ReplyStreamPacer.queuedLeadSeconds)
                == latest)
    }
}
