import Foundation
import Synchronization
@testable import HailDaemonKit

/// A synthetic admission boundary; advances causally between status and actual enqueue, not by sleeping.
final class PublicationExpiryClock: Sendable {
    private let origin = ContinuousClock.now
    private let readsRemaining = Mutex<Int?>(nil)
    func expireAfter(reads: Int) { readsRemaining.withLock { $0 = reads } }
    func instant() -> ContinuousClock.Instant {
        let expired = readsRemaining.withLock { remaining in
            guard let reads = remaining else { return false }
            guard reads > 0 else { return true }
            remaining = reads - 1
            return false
        }
        // Past the provider-turn bound too (#430): a committed leased request outlives the ordinary 120 s.
        return expired ? origin.advanced(by: HostReplyRequest.providerTurnBound) : origin
    }
}
