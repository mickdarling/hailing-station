import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Synthetic deterministic barriers only; the production operation must never wait like this test does.
private final class PublicationTestBarrier: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func signal() { entered.signal() }
    func hold() {
        signal()
        precondition(released.wait(timeout: .now() + 15) == .success, "synthetic publication timed out")
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [entered] in
                precondition(entered.wait(timeout: .now() + 15) == .success, "synthetic barrier timed out")
                continuation.resume()
            }
        }
    }
    func release() { released.signal() }
}

private final class PublicationTestEvents: Sendable {
    private let events = Mutex<[String]>([])
    func append(_ event: String) { events.withLock { $0.append(event) } }
    var snapshot: [String] { events.withLock { $0 } }
}

/// Blocking test operations run off Swift's cooperative executor; the test can always release its gate.
private enum PublicationTestWorker {
    static func run<Result: Sendable>(_ operation: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: operation()) }
        }
    }
}

@Suite struct ReplyPublicationAuthorityTests {
    @Test func invalidationPermanentlyRetiresOldPermitsWithoutExecutingTheirOperation() {
        let authority = ReplyPublicationAuthority()
        let original = authority.issuePermit()
        #expect(original.performIfCurrent { "before" } == "before")
        authority.invalidate()
        var calls = 0
        #expect(original.performIfCurrent { calls += 1; return true } == nil)
        let replacement = authority.issuePermit()
        #expect(replacement.performIfCurrent { true } == true)
        for _ in 0..<64 { authority.invalidate() }
        #expect(original.performIfCurrent { calls += 1; return true } == nil)
        #expect(replacement.performIfCurrent { calls += 1; return true } == nil)
        #expect(calls == 0)
    }

    @Test func gatesAreIndependentAndThrownOperationsReleaseTheirLock() throws {
        enum SyntheticFailure: Error { case expected }
        let first = ReplyPublicationAuthority()
        let second = ReplyPublicationAuthority()
        let permit = first.issuePermit()
        #expect(throws: SyntheticFailure.expected) {
            try permit.performIfCurrent { throw SyntheticFailure.expected }
        }
        #expect(permit.performIfCurrent { true } == true)
        first.invalidate()
        #expect(permit.performIfCurrent { true } == nil)
        #expect(second.issuePermit().performIfCurrent { true } == true)
    }

    @Test func alreadyStartedPublicationCompletesBeforeRevocationReturns() async {
        let authority = ReplyPublicationAuthority()
        let permit = authority.issuePermit()
        let publication = PublicationTestBarrier()
        let revocation = PublicationTestBarrier()
        let events = PublicationTestEvents()
        async let publishing: Bool = PublicationTestWorker.run {
            permit.performIfCurrent {
                events.append("publication entered")
                publication.hold()
                events.append("publication committed")
                return true
            } == true
        }
        await publication.wait()
        async let revoking: Void = PublicationTestWorker.run {
            events.append("revocation invoked")
            revocation.signal()
            authority.invalidate()
            events.append("revocation completed")
        }
        await revocation.wait()
        #expect(events.snapshot == ["publication entered", "revocation invoked"])
        publication.release()
        let published = await publishing
        #expect(published)
        await revoking
        #expect(events.snapshot == [
            "publication entered", "revocation invoked", "publication committed", "revocation completed"
        ])
        #expect(permit.performIfCurrent { true } == nil)
        #expect(authority.issuePermit().performIfCurrent { true } == true)
    }
}
