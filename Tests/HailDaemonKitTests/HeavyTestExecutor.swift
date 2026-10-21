import Foundation

/// #704: test bodies that compute for seconds or block on child processes run here, one at a time on a private serial
/// queue, never on Swift's cooperative pool. On a 3-core CI runner the pool has 3 threads, and two such bodies plus one
/// more held all of them, so every waiter in the shared test process overslept by up to 12 s. Use it through
/// `withTaskExecutorPreference(HeavyTestExecutor.shared) { … }`: the body stays in the test's task, so `#expect` and
/// `#require` still report against the test. Bodies run one after another, so a body here must never block waiting for
/// async work that needs this executor: it would wait forever.
final class HeavyTestExecutor: TaskExecutor {
    static let shared = HeavyTestExecutor()

    private let queue = DispatchQueue(label: "hail.tests.heavy")

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async { [self] in unowned.runSynchronously(on: asUnownedTaskExecutor()) }
    }
}
