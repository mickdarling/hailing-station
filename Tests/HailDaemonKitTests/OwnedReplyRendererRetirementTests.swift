#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite("Owned renderer retirement commitment")
struct OwnedReplyRendererRetirementTests {
    @Test func facadeDropCannotRelabelAlreadyCommittedNormalCleanupAsDeferred() async throws {
        let fixture = try RendererFixture(mode: "normal")
        defer { fixture.remove() }
        let release = DispatchSemaphore(value: 0)
        let reached = Mutex(false)
        let disposition = Mutex<OwnedReplyRendererCleanupDisposition?>(nil)
        var renderer: OwnedReplyRenderer? = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
            environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(cleanup: {
                reached.withLock { $0 = true }
                if release.wait(timeout: .now() + 3) == .timedOut {
                    Issue.record("normal cleanup commitment watchdog")
                }
            }, retired: { value in disposition.withLock { $0 = value } }))
        defer { release.signal() }
        let output = try #require(renderer?.outputDirectory)
        try await fixture.until("normal retirement fixture exit observed") { renderer?.isRunning == false }
        #expect(try Data(contentsOf: output.appendingPathComponent("synthetic.raw")) == Data([0, 0, 1, 0]))
        renderer?.retire(cancel: false)
        try await fixture.until("normal cleanup claim checkpoint") { reached.withLock { $0 } }
        // Both explicit cancellation and facade deinit happen after the legitimate normal claim.
        renderer?.cancel()
        renderer = nil
        #expect(disposition.withLock { $0 } == nil)
        release.signal()
        try await fixture.until("committed normal cleanup reported") { disposition.withLock { $0 != nil } }
        #expect(disposition.withLock { $0 } == .completed)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: fixture.outputRoot.path))
    }

    @Test func normalRetirementWhileRunningStillAllowsIdempotentCancellationBeforeCleanupClaim() async throws {
        let fixture = try RendererFixture(mode: "ignore-term")
        defer { fixture.remove() }
        let escalations = Mutex(0)
        let renderer = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
            environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(beforeEscalation: {
                escalations.withLock { $0 += 1 }
            }))
        try await fixture.until("pending normal retirement fixture ready") {
            FileManager.default.fileExists(atPath: fixture.record.path)
        }
        renderer.retire(cancel: false)
        #expect(renderer.isRunning)
        #expect(renderer.cleanupDisposition == .pending)
        renderer.retire(cancel: true)
        renderer.retire(cancel: true)
        renderer.cancel()
        await #expect(throws: OwnedReplyRendererError.cleanupDeferred) { try await renderer.waitForCleanup() }
        await renderer.waitForCancellationSignals()
        #expect(escalations.withLock { $0 } == 1)
        try await fixture.until("pending normal retirement cancelled child reaped") { !renderer.isRunning }
        #expect(renderer.cleanupDisposition == .deferred)
        #expect(!renderer.cleanupComplete)
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
    }
}
#endif
