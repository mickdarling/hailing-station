#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// A deferred cleanup removes only the renderer's own folder, and only when it is empty (#800).
@Suite("Owned renderer deferred cleanup")
struct OwnedReplyRendererDeferredTests {
    /// #800: the empty-folder removal checks the name still names the folder this renderer made. A child that moved
    /// it aside and left another empty folder under the same name gets neither removed.
    @Test func aDeferredCleanupNeverRemovesAFolderItDidNotMake() async throws {
        let fixture = try RendererFixture(mode: "swap-folder")
        defer { fixture.remove() }
        let renderer = try fixture.start()
        try await fixture.until("swapping renderer reaped") { !renderer.isRunning }
        await #expect(throws: OwnedReplyRendererError.nonzeroExit) { try await renderer.requireSuccessfulExit() }
        renderer.retire(cancel: false)
        await #expect(throws: OwnedReplyRendererError.cleanupDeferred) { try await renderer.waitForCleanup() }
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path), "the stand-in was removed")
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path + ".moved"))
    }

    /// #800: a renderer reaped before retirement, as on nonzero exit, reports its deferral only once its empty folder
    /// is gone. The CLI exits as soon as `waitForCleanup` returns, so an earlier report would strand the folder.
    @Test func aReapedFailureReportsOnlyAfterItsEmptyFolderIsGone() async throws {
        let fixture = try RendererFixture(mode: "nonzero")
        defer { fixture.remove() }
        let leftAtReport = Mutex<[String]?>(nil)
        let renderer = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
            environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(retired: { _ in
                let left = try? FileManager.default.contentsOfDirectory(atPath: fixture.outputRoot.path)
                leftAtReport.withLock { $0 = left }
            }))
        try await fixture.until("failed renderer reaped") { !renderer.isRunning }
        renderer.retire(cancel: false)
        await #expect(throws: OwnedReplyRendererError.cleanupDeferred) { try await renderer.waitForCleanup() }
        try await fixture.until("deferral reported") { leftAtReport.withLock { $0 } != nil } // The hook follows.
        #expect(leftAtReport.withLock { $0 } == [])
    }
}
#endif
