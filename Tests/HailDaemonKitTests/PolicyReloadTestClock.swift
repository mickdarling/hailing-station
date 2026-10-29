import Foundation
import Synchronization

/// Only synthetic read cost advances time; process coordination never sleeps on the cooperative pool.
final class PolicyReloadTestClock: Sendable {
    private let origin = ContinuousClock.now
    private let elapsed = Mutex<Duration>(.zero)

    var now: ContinuousClock.Instant { origin.advanced(by: delay) }
    var delay: Duration { elapsed.withLock { $0 } }
    func advance(_ duration: Duration) { elapsed.withLock { $0 += duration } }
}
