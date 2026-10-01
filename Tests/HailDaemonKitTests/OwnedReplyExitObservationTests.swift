#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct OwnedReplyExitObservationTests {
    @Test func inconclusiveExitNotificationRetriesWithoutDeadlineOrSignals() async throws {
        for interrupted in [true, false] {
            let fixture = try PublisherFixture()
            let notified = Mutex(false)
            let attempts = Mutex(0)
            let signals = Mutex<[Int32]>([])
            var hooks = OwnedReplyGroupHooks()
            hooks.exitNotification = { notified.withLock { $0 = true } }
            hooks.signal = { value in signals.withLock { $0.append(value) } }
            hooks.wait = { leader, information in
                let result = waitid(P_PID, id_t(leader), &information, WEXITED | WNOHANG | WNOWAIT)
                let error = errno
                guard result == 0, information.si_pid == leader,
                      [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(information.si_code) else {
                    return (result, error)
                }
                // Hold actual terminal metadata until the real process exit notification.
                // WNOWAIT preserves exact child ownership throughout these injected observations.
                guard notified.withLock({ $0 }) else { information = siginfo_t(); return (0, 0) }
                let attempt = attempts.withLock { value in value += 1; return value }
                if attempt <= 2 {
                    information = siginfo_t()
                    return interrupted ? (-1, EINTR) : (0, 0)
                }
                return (result, error)
            }
            let publisher = try fixture.publisher(hooks: hooks)
            let result = await Task { try await publisher.publish(fixture.reply()) }.result
            if case .failure(let error) = result {
                #expect(Bool(false), "inconclusive exit was misreported: \(error)")
            }
            #expect(attempts.withLock { $0 } >= 3)
            #expect(signals.withLock { $0 } == [SIGCONT])
            try await PublisherFixture.until { publisher.diagnostics().retained == 0 }
            #expect(publisher.diagnostics().completed == 1 && publisher.diagnostics().failed == 0)
            #expect(publisher.diagnostics().lastCleanupFailure == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
            try await fixture.shutdown(publisher)
        }
    }
}
#endif
