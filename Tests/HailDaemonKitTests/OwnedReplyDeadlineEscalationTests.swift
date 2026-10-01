#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct OwnedReplyDeadlineEscalationTests {
    @Test func readinessProvenDeadlineEscalatesTERMignoringGroupAndExitedLeadersDescendant() async throws {
        for mode in ["ignore", "descendant"] {
            let fixture = try PublisherFixture(mode: mode)
            let probe = OwnedReplyDeadlineProbe()
            let job = try probe.job(fixture)
            job.activate(cancelled: false)
            do {
                try await PublisherFixture.until { FileManager.default.fileExists(atPath: fixture.record.path) }
                // Invoke the actual deadline transition only after the fixture has installed its
                // TERM behavior and created descendants. Actual timer expiry has separate coverage.
                job.cancel(.deadline)
                try await PublisherFixture.until { probe.cleaned.withLock { $0 } }
                if case .failure(.deadline) = probe.outcome.withLock({ $0 }) {} else {
                    #expect(Bool(false), "expected one fixed deadline outcome")
                }
                #expect(probe.outcomeCount.withLock { $0 } == 1)
                let signals = probe.signals.withLock { $0 }
                #expect(signals.filter { $0 == SIGTERM }.count == 1)
                #expect(signals.filter { $0 == SIGKILL }.count == 1)
                #expect(probe.cleanupFailure.withLock { $0 } == nil)
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
                try FileManager.default.removeItem(at: fixture.base)
            } catch {
                job.cancel(.cancelled)
                try await PublisherFixture.until { probe.cleaned.withLock { $0 } }
                try FileManager.default.removeItem(at: fixture.base)
                throw error
            }
        }
    }
}

private final class OwnedReplyDeadlineProbe: Sendable {
    let signals = Mutex<[Int32]>([])
    let outcome = Mutex<Result<Void, OwnedReplyPublisherError>?>(nil)
    let outcomeCount = Mutex(0)
    let cleaned = Mutex(false)
    let cleanupFailure = Mutex<OwnedReplyPublisherError?>(nil)

    func job(_ fixture: PublisherFixture) throws -> OwnedReplyGroupJob {
        var hooks = OwnedReplyGroupHooks()
        hooks.signal = { value in self.signals.withLock { $0.append(value) } }
        let configuration = OwnedReplyPublisherConfiguration(
            executable: fixture.executable, socket: fixture.base.appendingPathComponent("reply.sock"),
            root: fixture.root, hostID: "synthetic-host", environment: fixture.environment,
            deadline: .seconds(30), hooks: hooks)
        return try OwnedReplyGroupJob(configuration: configuration, reply: fixture.reply(), cancelled: { false },
            outcome: { result in
                self.outcome.withLock { $0 = result }; self.outcomeCount.withLock { $0 += 1 }
            },
            cleanup: .init(cleaned: { self.cleaned.withLock { $0 = true } },
                           failed: { error in self.cleanupFailure.withLock { $0 = error } }))
    }
}
#endif
