import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// Synthetic completions and an owner-local Unix socket; no device, provider or captured audio.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ReplySendDeadline904Tests {
    @Test func deadlineAbandonmentPreservesTransportRegression904() async throws {
        let transport = ReplyTransportLifecycle()
        let callback = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
        let cancellations = Mutex(0)
        let ticket = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { completion in
            callback.withLock { $0 = completion }
        }, cancel: { _ in cancellations.withLock { $0 += 1 } })
        #expect(ticket.enqueue())
        #expect(await cancelledResult(ticket) == .abandoned)
        #expect(cancellations.withLock { $0 } == 0)
        #expect(!transport.isRetired)
        let next = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { $0(nil) })
        #expect(next.enqueue())
        #expect(await next.result() == .sent)
        let complete = try #require(callback.withLock { stored in
            defer { stored = nil }
            return stored
        })
        complete(nil)
        #expect(await ticket.result() == .abandoned)
        #expect(cancellations.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func lateCompletionAfterAbandonmentFailsOnlyForTransportError(fails: Bool) async throws {
        let transport = ReplyTransportLifecycle()
        let callback = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
        let closed = AsyncStream<String>.makeStream()
        let reasons = Mutex<[String]>([])
        let observed = Mutex(0)
        let ticket = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { completion in
            callback.withLock { $0 = completion }
        }, onLateSuccess: { observed.withLock { $0 += 1 } }, cancel: { reason in
            reasons.withLock { $0.append(reason) }
            closed.continuation.yield(reason)
        }, stallGrace: .seconds(30)) // This tests completion, not watchdog expiry under scheduler contention.
        #expect(ticket.enqueue())
        #expect(await cancelledResult(ticket) == .abandoned)
        let complete = try #require(callback.withLock { stored in
            defer { stored = nil }
            return stored
        })
        complete(fails ? .posix(.EPIPE) : nil)
        complete(.posix(.ECONNRESET)) // Duplicate callbacks cannot replace the first outcome or close twice.
        if fails {
            var closures = closed.stream.makeAsyncIterator()
            #expect(await closures.next() == "host reply send failed: \(NWError.posix(.EPIPE))")
        }
        #expect(transport.isRetired == fails)
        #expect(reasons.withLock { $0.count } == (fails ? 1 : 0))
        #expect(observed.withLock { $0 } == (fails ? 0 : 1))
        #expect(await ticket.result() == .abandoned)
        closed.continuation.finish()
    }

    @Test func abandonedSendGraceClosesOnceAndRefusesLaterEnqueue() async throws {
        let transport = ReplyTransportLifecycle()
        let callback = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
        let closed = AsyncStream<String>.makeStream()
        let count = Mutex(0)
        let observed = Mutex(0)
        let permit = try #require(transport.issuePermit())
        let ticket = PreparedWebSocketReply(permit: permit, submit: { completion in
            callback.withLock { $0 = completion }
        }, onLateSuccess: { observed.withLock { $0 += 1 } }, cancel: { reason in
            count.withLock { $0 += 1 }
            closed.continuation.yield(reason)
        }, stallGrace: .milliseconds(20))
        #expect(ticket.enqueue())
        #expect(await cancelledResult(ticket) == .abandoned)
        var closures = closed.stream.makeAsyncIterator()
        #expect(await closures.next() == "host reply send stalled")
        #expect(transport.isRetired)
        #expect(observed.withLock { $0 } == 0) // No completion before watchdog closure means no echo observation.
        let next = PreparedWebSocketReply(permit: permit, submit: { _ in Issue.record("enqueue after closure") })
        #expect(!next.enqueue())
        let complete = try #require(callback.withLock { stored in
            defer { stored = nil }
            return stored
        })
        complete(nil)
        complete(.posix(.EPIPE))
        #expect(await ticket.result() == .abandoned)
        #expect(count.withLock { $0 } == 1)
        #expect(observed.withLock { $0 } == 0) // Even an impossible callback after closure stays inert.
        closed.continuation.finish()
    }

    @Test func inlineTransportErrorIsTypedAndClosesWithoutReenteringPermitGate() async throws {
        let transport = ReplyTransportLifecycle()
        let closed = AsyncStream<String>.makeStream()
        let ticket = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: {
            $0(.posix(.ECONNRESET))
        }, cancel: { closed.continuation.yield($0) })
        #expect(ticket.enqueue())
        #expect(await ticket.result() == .failed(String(describing: NWError.posix(.ECONNRESET))))
        var closures = closed.stream.makeAsyncIterator()
        #expect(await closures.next() == "host reply send failed: \(NWError.posix(.ECONNRESET))")
        #expect(transport.isRetired)
        closed.continuation.finish()
    }

    @Test func staleEnqueueResumesAlreadyWaitingCaller() async throws {
        let transport = ReplyTransportLifecycle()
        let admitted = AsyncStream<Void>.makeStream()
        let ticket = PreparedWebSocketReply(permit: try #require(transport.issuePermit()), submit: { _ in
            Issue.record("stale ticket submitted")
        }, waiterAdmitted: { admitted.continuation.yield(()) })
        let waiter = Task { await ticket.result() }
        var admissions = admitted.stream.makeAsyncIterator()
        _ = try #require(await admissions.next())
        transport.retire()
        #expect(!ticket.enqueue())
        #expect(await waiter.value == .refused)
        admitted.continuation.finish()
    }
}

private func cancelledResult(_ ticket: PreparedWebSocketReply) async -> PreparedWebSocketReply.Outcome {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await ticket.result()
    }
    return await task.value
}
