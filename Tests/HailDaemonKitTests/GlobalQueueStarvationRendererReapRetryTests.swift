#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

extension GlobalQueueStarvationTests {
    /// An exit notification that precedes waitpid readiness must retry without a constrained worker.
    @Suite struct OwnedReplyRendererReapRetry {
        @Test func aRendererReapRetriesOnTimeAfterAnExitObservationIsNotReady() async throws {
            let fixture = try RendererFixture(mode: "retirement-race")
            defer { fixture.remove() }
            let observations = Mutex(0)
            let renderer = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
                environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(deferObservedExit: {
                    observations.withLock { count in
                        count += 1
                        return count == 1
                    }
                }))
            defer { renderer.retire(cancel: true) }
            try await fixture.until("controlled-exit fixture ready") {
                FileManager.default.fileExists(atPath: fixture.record.path)
            }
            let (_, elapsed) = try await whileGlobalQueueStarved {
                try Data().write(to: URL(fileURLWithPath: fixture.record.path + ".exit"))
                try await renderer.requireSuccessfulExit()
                renderer.retire(cancel: false)
                try await renderer.waitForCleanup()
            }
            #expect(observations.withLock { $0 } >= 2, "the deferred observation must be retried")
            #expect(!renderer.isRunning)
            #expect(renderer.cleanupComplete)
            #expect(elapsed < GlobalQueueStarvationTests.bound, "reap retry and cleanup took \(elapsed)")
        }
    }
}
#endif
