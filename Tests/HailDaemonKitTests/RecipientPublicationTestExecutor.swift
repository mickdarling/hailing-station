import Foundation
import Synchronization

/// Blocking synthetic actor jobs must not occupy Swift's cooperative pool while revocation runs there.
final class RecipientPublicationExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "synthetic.recipient-publication")
    private let marker = DispatchSpecificKey<Bool>()

    init() { queue.setSpecific(key: marker, value: true) }

    var isExecuting: Bool { DispatchQueue.getSpecific(key: marker) == true }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { [self] in unowned.runSynchronously(on: asUnownedTaskExecutor()) }
    }
}

enum RecipientPublicationTestError: Error { case admissionTimedOut }

/// Timeout releases the test as a recoverable failure, never a process-wide precondition trap.
final class RecipientPublicationGate: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let timeout: DispatchTimeInterval
    private let state = Mutex((released: false, timedOut: false, dedicatedQueue: false))

    init(timeout: DispatchTimeInterval = .seconds(15)) { self.timeout = timeout }

    var timedOut: Bool { state.withLock { $0.timedOut } }
    var usedDedicatedQueue: Bool { state.withLock { $0.dedicatedQueue } }

    func block(onDedicatedQueue: Bool) -> Bool {
        state.withLock { $0.dedicatedQueue = onDedicatedQueue }
        entered.signal()
        let success = released.wait(timeout: .now() + timeout) == .success
        state.withLock { $0.timedOut = !success }
        return success
    }

    func waitEntered() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async { [entered, timeout] in
                if entered.wait(timeout: .now() + timeout) == .success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RecipientPublicationTestError.admissionTimedOut)
                }
            }
        }
    }

    func release() {
        let shouldSignal = state.withLock { state in
            guard !state.released else { return false }
            state.released = true
            return true
        }
        if shouldSignal { released.signal() }
    }
}
