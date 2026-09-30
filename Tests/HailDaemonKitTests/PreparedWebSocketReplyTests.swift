import Foundation
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite struct PreparedWebSocketReplyTests {
    @Test func completionBeforeWaitingIsBufferedAndOnlyOneEnqueueOccurs() async {
        let authority = ReplyPublicationAuthority()
        let submissions = Mutex(0)
        let ticket = PreparedWebSocketReply(permit: authority.issuePermit(), submit: { completion in
            submissions.withLock { $0 += 1 }
            completion(true)
            completion(false)
        })
        #expect(ticket.enqueue())
        #expect(!ticket.enqueue())
        #expect(await ticket.result())
        #expect(await ticket.result())
        #expect(submissions.withLock { $0 } == 1)
    }

    @Test func staleTransportPermitRefusesWithoutInvokingSender() async {
        let authority = ReplyPublicationAuthority()
        let submissions = Mutex(0)
        let ticket = PreparedWebSocketReply(permit: authority.issuePermit(), submit: { completion in
            submissions.withLock { $0 += 1 }
            completion(true)
        })
        authority.invalidate()
        #expect(!ticket.enqueue())
        #expect(!(await ticket.result()))
        #expect(submissions.withLock { $0 } == 0)
    }

    @Test func cancellationBeforeWaitingCompletesFalseOnceAndPreventsLaterSubmission() async {
        let authority = ReplyPublicationAuthority()
        let cancellations = Mutex(0)
        let submissions = Mutex(0)
        let ticket = PreparedWebSocketReply(permit: authority.issuePermit(), submit: { completion in
            submissions.withLock { $0 += 1 }
            completion(true)
        }, cancel: { cancellations.withLock { $0 += 1 } })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ticket.result()
        }
        #expect(!(await task.value))
        #expect(!ticket.enqueue())
        #expect(!(await ticket.result()))
        #expect(cancellations.withLock { $0 } == 1)
        #expect(submissions.withLock { $0 } == 0)
    }

    @Test func cancellationAfterEnqueueWinsOverLaterCompletion() async throws {
        let authority = ReplyPublicationAuthority()
        let callback = Mutex<(@Sendable (Bool) -> Void)?>(nil)
        let cancellations = Mutex(0)
        let ticket = PreparedWebSocketReply(permit: authority.issuePermit(), submit: { completion in
            callback.withLock { $0 = completion }
        }, cancel: { cancellations.withLock { $0 += 1 } })
        #expect(ticket.enqueue())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ticket.result()
        }
        #expect(!(await task.value))
        let complete = try #require(callback.withLock { stored in
            defer { stored = nil }
            return stored
        })
        complete(true)
        #expect(!(await ticket.result()))
        #expect(cancellations.withLock { $0 } == 1)
    }

    @Test func closingPeerInvalidatesPreviouslyPreparedTicketAndFurtherPreparation() async throws {
        let (host, _) = try await sessionHost()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let peer = WebSocketPeer(
            id: UUID(), connection: connection, session: HostSession(host: host),
            queue: DispatchQueue(label: "synthetic-prepared-reply"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }
        )
        let prepared = try #require(await peer.prepareReplyPublication(helloFrame()))
        await peer.finish(reason: "synthetic closure")
        #expect(!prepared.enqueue())
        #expect(!(await prepared.result()))
        #expect(await peer.prepareReplyPublication(helloFrame()) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledRejectedWaiterCannotCancelLegitimatePendingWaiter() async throws {
        let authority = ReplyPublicationAuthority()
        let callback = Mutex<(@Sendable (Bool) -> Void)?>(nil)
        let cancellations = Mutex(0)
        let admission = AsyncStream<Void>.makeStream()
        let ticket = PreparedWebSocketReply(permit: authority.issuePermit(), submit: { completion in
            callback.withLock { $0 = completion }
        }, cancel: { cancellations.withLock { $0 += 1 } }, waiterAdmitted: {
            admission.continuation.yield(())
        })
        #expect(ticket.enqueue())
        let first = Task { await ticket.result() }
        var arrivals = admission.stream.makeAsyncIterator()
        _ = try #require(await arrivals.next())
        let rejected = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ticket.result()
        }
        #expect(!(await rejected.value))
        #expect(cancellations.withLock { $0 } == 0)
        let complete = try #require(callback.withLock { stored in
            defer { stored = nil }
            return stored
        })
        complete(true)
        #expect(await first.value)
        #expect(await ticket.result())
        #expect(cancellations.withLock { $0 } == 0)
        admission.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingCloseFrameAlreadyRefusesPreparedAndOrdinaryPublication() async throws {
        let (host, _) = try await sessionHost()
        let completion = Mutex<(@Sendable () -> Void)?>(nil)
        let closeSubmitted = AsyncStream<Void>.makeStream()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let peer = WebSocketPeer(
            id: UUID(), connection: connection, session: HostSession(host: host),
            queue: DispatchQueue(label: "synthetic-pending-close"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitClose: { callback in
                completion.withLock { $0 = callback }
                closeSubmitted.continuation.yield(())
            }
        )
        let prepared = try #require(await peer.prepareReplyPublication(helloFrame()))
        let close = Task { await peer.close(reason: "synthetic held close") }
        var submissions = closeSubmitted.stream.makeAsyncIterator()
        _ = try #require(await submissions.next())
        #expect(!(await peer.ended))
        #expect(!prepared.enqueue())
        #expect(!(await prepared.result()))
        #expect(await peer.prepareReplyPublication(helloFrame()) == nil)
        #expect(!(await peer.send(helloFrame())))
        let finishClose = try #require(completion.withLock { stored in
            defer { stored = nil }
            return stored
        })
        finishClose()
        await close.value
        #expect(await peer.ended)
        closeSubmitted.continuation.finish()
    }
}
