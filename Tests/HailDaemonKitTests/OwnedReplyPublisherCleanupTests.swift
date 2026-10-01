#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct OwnedReplyPublisherCleanupTests {
    @Test func blockedCleanupDoesNotHoldCallerAndStillOccupiesAdmission() async throws {
        let fixture = try PublisherFixture()
        let checkpoint = PublisherCheckpoint()
        var hooks = OwnedReplyGroupHooks()
        hooks.beforeCleanup = { _ in checkpoint.pause() }
        let publisher = try fixture.publisher(hooks: hooks)
        let task = Task { try await publisher.publish(fixture.reply()) }
        do {
            try await PublisherFixture.until { checkpoint.reached && publisher.diagnostics().completed == 1 }
            try await task.value
            task.cancel(); publisher.stop()
            #expect(publisher.diagnostics().retained == 1)
            #expect(publisher.diagnostics().completed == 1 && publisher.diagnostics().failed == 0)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 1)
            checkpoint.resume()
            try await fixture.shutdown(publisher)
        } catch {
            checkpoint.resume(); task.cancel(); _ = await task.result
            try await fixture.shutdown(publisher); throw error
        }
    }

    @Test func cleanupFailureIsSeparateFromAcknowledgementAndRetainsResource() async throws {
        let fixture = try PublisherFixture()
        let mutated = Mutex(false)
        var hooks = OwnedReplyGroupHooks()
        hooks.beforeCleanup = { url in
            do {
                try FileManager.default.moveItem(at: url, to: fixture.root.appendingPathComponent("preserved"))
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                mutated.withLock { $0 = true }
            } catch {} // A failed fixture mutation remains an explicit expectation failure below.
        }
        let publisher = try fixture.publisher(hooks: hooks)
        try await publisher.publish(fixture.reply()) // This proves pinned quiescence + exact child reap.
        try await PublisherFixture.until { publisher.diagnostics().lastCleanupFailure == .cleanupFailed }
        #expect(mutated.withLock { $0 })
        let status = publisher.diagnostics()
        #expect(status.completed == 1 && status.failed == 0 && status.retained == 1)
        publisher.stop()
        #expect(publisher.diagnostics().completed == 1 && publisher.diagnostics().retained == 1)
        // Controlled fixture-only recovery after proven quiescence. The production admission stays
        // retained; this does not supply automatic unknown-ownership recovery or broad deletion.
        try FileManager.default.removeItem(at: fixture.base)
    }
}
#endif
