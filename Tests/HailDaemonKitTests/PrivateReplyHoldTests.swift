import Dispatch
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #913: the privacy reply hold's enqueue. A held connection never runs its enqueue, and an entry cannot land inside an
/// enqueue already running: `set` takes the same lock, so it waits until the enqueue is done.
@Suite struct PrivateReplyHoldTests {
    /// Held, the enqueue never runs; another connection's does, and its own refusal passes through; released, it runs.
    @Test func aHeldConnectionNeverRunsItsEnqueue() {
        let hold = PrivateReplyHold()
        let (held, other) = (UUID(), UUID())
        hold.set(true, connection: held)
        var ran: [UUID] = []
        let enqueue = { (connection: UUID) in
            hold.unlessHeld(connection) {
                ran.append(connection)
                return true
            }
        }
        #expect(!enqueue(held))
        #expect(enqueue(other))
        #expect(!hold.unlessHeld(other) { false })
        hold.set(false, connection: held)
        #expect(enqueue(held))
        #expect(ran == [other, held])
    }

    /// An entry made while an enqueue runs waits for it: inside the enqueue, the entry (on another thread, started
    /// only once the enqueue is running) never completes, so the enqueue's bounded wait for it times out. The bound
    /// never decides a pass: with the lock held, the entry cannot complete within any wait. Once the enqueue returns,
    /// the entry lands, and the next enqueue is refused.
    @Test func anEntryWaitsForAnEnqueueInProgress() async {
        let hold = PrivateReplyHold()
        let connection = UUID()
        let (entered, entry) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        let landedInside = Mutex(false)
        async let entryDone: Void = withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                hold.set(true, connection: connection)
                entry.signal()
                continuation.resume()
            }
        }
        let enqueued = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = hold.unlessHeld(connection) {
                    entered.signal()
                    let landed = entry.wait(timeout: .now() + .seconds(1)) == .success
                    landedInside.withLock { $0 = landed }
                    return true
                }
                continuation.resume(returning: result)
            }
        }
        await entryDone
        #expect(enqueued)
        #expect(!landedInside.withLock { $0 }, "the entry landed while the enqueue was running")
        #expect(hold.holds(connection))
        #expect(!hold.unlessHeld(connection) { true })
    }
}
