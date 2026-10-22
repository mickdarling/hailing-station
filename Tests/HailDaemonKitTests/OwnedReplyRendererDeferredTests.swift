#if os(macOS)
import Foundation
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
        try await Task.sleep(for: .milliseconds(500)) // The removal runs on the cleanup queue after the report.
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path), "the stand-in was removed")
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path + ".moved"))
    }
}
#endif
