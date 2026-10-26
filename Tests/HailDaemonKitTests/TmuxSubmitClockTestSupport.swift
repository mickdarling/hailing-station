import Synchronization
@testable import HailDaemonKit

/// #917: one poll is one step. Scripted command latency and scheduler stalls never advance this clock.
/// Sleeps cannot park a continuation; even zero/negative intervals advance, so finite deadlines stay bounded.
/// Scripted suites also have real time limits, and verification phases have a process watchdog.
final class ManualSubmitClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    var clock: TmuxSubmitClock {
        TmuxSubmitClock(now: { self.now }, sleep: { duration in
            self.instant.withLock { $0 = $0.advanced(by: max(duration, .milliseconds(1))) }
            await Task.yield()
        })
    }
}
