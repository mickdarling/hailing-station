import Foundation
import Synchronization

final class RecipientTestClock: Sendable {
    private let value = Mutex<Int64>(1_700_000_000_000)
    private let origin = ContinuousClock.now
    private let elapsed = Mutex<Int64>(0)
    func now() -> Int64 { value.withLock { $0 } }
    func instant() -> ContinuousClock.Instant { origin.advanced(by: .milliseconds(elapsed.withLock { $0 })) }
    func advance(_ milliseconds: Int64) {
        value.withLock { $0 += milliseconds }
        elapsed.withLock { $0 += milliseconds }
    }
    func adjustWallClock(_ milliseconds: Int64) { value.withLock { $0 += milliseconds } }
}
