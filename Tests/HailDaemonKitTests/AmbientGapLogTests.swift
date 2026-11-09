#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

extension AmbientGapFillTests {
    @Test func logCoalescesEachSecondAndFlushesOnlyTheRemainder() throws {
        let clock = AmbientGapTestClock(), lines = Mutex<[String]>([])
        let log = AmbientGapLog { detail in lines.withLock { $0.append(detail) } }
        let gap = try #require(AmbientGapFill(after: 0, sequence: 2, budget: .milliseconds(100)))
        let zero = try #require(AmbientGapFill(after: 0, sequence: 99, budget: .zero))
        #expect(log.record(nil, at: clock.now) == nil)
        for index in 1...25 {
            clock.advance(.milliseconds(100))
            let detail = log.record(gap, at: clock.now)
            // Recording returns the periodic line without calling external logging under the caller's lock.
            #expect(lines.withLock { $0.count } == (index - 1) / 10)
            if let detail { log.emit?(detail) }
            #expect(log.record(zero, at: clock.now) == nil)
            #expect(lines.withLock { $0.count } == index / 10)
        }
        log.flush()
        log.flush() // Repeated EOF/teardown cannot double count.
        #expect(lines.withLock { $0 } == [
            "fills=10 missing=10 filled_ms=1000 capped=0",
            "fills=10 missing=10 filled_ms=1000 capped=0",
            "fills=5 missing=5 filled_ms=500 capped=0"
        ])
    }
}
#endif
