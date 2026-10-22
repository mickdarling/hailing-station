import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The end-of-session summary takes the consumer's `busy` as a request does (#735 H-5): it waits for an event in
/// flight, an event arriving meanwhile waits for it, and neither is refused; a summary whose hold is gone by then is
/// not sent. Synthetic text only.
extension RightyoInputConsumerTests {
    /// A "discard that", a new session or the stream's retirement before the summary is handed off means it is not
    /// sent: the hold it was for is gone.
    @Test(arguments: ["discard", "begin", "end"])
    func aStaleSummaryIsNotSent(_ change: String) async throws {
        let step = RecordingDispatcher()
        let ended = try await endedDuck(["A synthetic thought."])
        switch change {
        case "discard": _ = ended.session.discardHeld()
        case "begin": ended.session.begin()
        default: ended.session.end()
        }
        #expect(await ended.consumer.summarizeDuck(try #require(ended.held), via: step) == .skipped)
        #expect(await step.calls.isEmpty)
    }

    /// The summary takes `busy` as a request does: with a request in flight at the exit, it waits for it, and neither
    /// is refused.
    @Test func theSummaryWaitsForARequestInFlight() async throws {
        let own = GatedDispatcher(), step = RecordingDispatcher()
        let ended = try await endedDuck(["A synthetic thought."], dispatcher: own)
        let hold = try #require(ended.held)
        let request = Task { try await ownerRequest("A synthetic request.", to: ended.consumer, at: ended.next) }
        #expect(await eventually { await own.calls == 1 })
        let summary = Task { await ended.consumer.summarizeDuck(hold, via: step) }
        for _ in 0..<20 { await Task.yield() }
        #expect(await step.calls.isEmpty)
        await own.release()
        #expect(try await request.value)
        #expect(await summary.value == .sent(turns: 1, bytes: hold.copy.bytes))
        #expect(await step.calls.count == 1)
    }

    /// An event arriving while the summary is in flight waits for it instead of being refused.
    @Test func anEventWaitsForTheSummary() async throws {
        let step = GatedDispatcher()
        let ended = try await endedDuck(["A synthetic thought."])
        let hold = try #require(ended.held)
        let summary = Task { await ended.consumer.summarizeDuck(hold, via: step) }
        #expect(await eventually { await step.calls == 1 })
        let done = Mutex(false)
        let line = try duckTurn("A later synthetic line.", sequence: ended.next)
        let event = Task {
            defer { done.withLock { $0 = true } }
            return try await ended.consumer.consume(line)
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!done.withLock { $0 })
        await step.release()
        #expect(await summary.value == .sent(turns: 1, bytes: hold.copy.bytes))
        #expect(try await !event.value)
    }
}

/// A delivery step whose first dispatch waits until `release`; later ones go straight through.
actor GatedDispatcher: RightyoDispatching {
    private(set) var calls = 0
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?

    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        calls += 1
        if !released { await withCheckedContinuation { waiting = $0 } }
        return RightyoDispatchReceipt(request: UUID())
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}
