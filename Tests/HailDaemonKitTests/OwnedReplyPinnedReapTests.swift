#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct OwnedReplyPinnedReapTests {
    @Test func pinnedReapRequiresExactLeaderAndRetriesOnlyInterruptions() {
        for observation: (pid_t, Int32) in [(0, 0), (43, 0), (-1, ECHILD), (-1, EIO)] {
            var attempts = 0
            let reaped = OwnedReplyGroupJob.reapPinnedLeader(42) { leader in
                #expect(leader == 42)
                attempts += 1
                return observation
            }
            #expect(!reaped && attempts == 1)
        }
    }

    @Test func interruptedPinnedReapRetriesWithoutSignalsOrRetainedAdmission() async throws {
        let fixture = try PublisherFixture()
        let attempts = Mutex(0)
        let cutoff = Mutex(false)
        let lateSignals = Mutex(0)
        var hooks = OwnedReplyGroupHooks()
        hooks.beforeReap = { cutoff.withLock { $0 = true } }
        hooks.signal = { _ in
            if cutoff.withLock({ $0 }) { lateSignals.withLock { $0 += 1 } }
        }
        hooks.reap = { leader in
            let attempt = attempts.withLock { current in current += 1; return current }
            if attempt <= 3 { return (-1, EINTR) }
            var status: Int32 = 0
            let result = waitpid(leader, &status, WNOHANG)
            return (result, errno)
        }
        let publisher = try fixture.publisher(hooks: hooks)
        let result = await Task { try await publisher.publish(fixture.reply()) }.result
        #expect(attempts.withLock { $0 } == 4)
        if case .failure(let error) = result {
            #expect(Bool(false), "interrupted exact reap failed: \(error)")
        }
        #expect(lateSignals.withLock { $0 } == 0)
        #expect(publisher.diagnostics().lastCleanupFailure == nil)
        // A failing old implementation keeps its owned child and root for evidence; do not
        // simulate ownership recovery, delete that retained root or reap a raw identity here.
        guard attempts.withLock({ $0 }) == 4 else { publisher.stop(); return }
        try await PublisherFixture.until { publisher.diagnostics().retained == 0 }
        #expect(publisher.diagnostics().completed == 1 && publisher.diagnostics().failed == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        try await fixture.shutdown(publisher)
    }
}
#endif
