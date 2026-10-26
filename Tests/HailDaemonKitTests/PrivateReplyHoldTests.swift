import Dispatch
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #913: the privacy reply hold's enqueue. A held connection never runs its enqueue, and an entry cannot land inside an
/// enqueue already running: `set` takes the same lock, so it waits until the enqueue is done. That enqueue only hands
/// the frame to the transport, so a stalled send never holds up a privacy decision.
@Suite(.timeLimit(.minutes(1))) struct PrivateReplyHoldTests {
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

    /// Jarvis: a privacy decision never waits behind a slow socket. A host clip's frame goes through the hold to a
    /// synthetic transport that takes it at once and withholds its completion. Once the frame is submitted, entries for
    /// this connection and another complete while that send is still stalled: only the enqueue, never its completion,
    /// runs under the hold's lock. The bounded wait never decides a pass; it only limits how long a regression (a
    /// completion awaited under the lock) takes to fail, after which the send is completed so nothing hangs.
    @Test func aStalledSendNeverDelaysAPrivacyDecision() async throws {
        let env = try await ReplyEchoRig904.make(route: "single_selector")
        let hold = await env.listener.replyHold
        let (connection, other) = (await env.session.connectionID, UUID())
        var submissions = env.sender.submissions.stream.makeAsyncIterator()
        let frame = env.frames[0]
        let delivery = Task { await env.peer.deliverRequestlessReply(frame, hold: hold) }
        _ = try #require(await submissions.next())
        let decided = await Self.decides(hold, [other, connection])
        #expect(decided, "a privacy decision waited behind a stalled send")
        #expect(env.sender.callback.withLock { $0 != nil }, "the send was still stalled when privacy was decided")
        try env.sender.complete()
        guard case .delivered = await delivery.value else {
            Issue.record("the frame submitted before the decision was not delivered")
            return
        }
        #expect(hold.holds(connection) && hold.holds(other))
    }

    /// Sets `connections` held on another thread; whether that finished within the bound.
    private static func decides(_ hold: PrivateReplyHold, _ connections: [UUID]) async -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            connections.forEach { hold.set(true, connection: $0) }
            done.signal()
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: done.wait(timeout: .now() + .seconds(10)) == .success)
            }
        }
    }
}
