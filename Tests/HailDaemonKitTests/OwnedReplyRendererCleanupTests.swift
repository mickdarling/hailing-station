#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite("Owned renderer descriptor cleanup")
struct OwnedReplyRendererCleanupTests {
    @Test func deferredDispositionPrecedesEscalationCompletionAndKernelReaping() async throws {
        let fixture = try RendererFixture(mode: "ignore-term")
        defer { fixture.remove() }
        let release = DispatchSemaphore(value: 0)
        let reached = Mutex(false)
        let renderer = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
            environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(beforeEscalation: {
                reached.withLock { $0 = true }
                if release.wait(timeout: .now() + 3) == .timedOut { Issue.record("escalation barrier watchdog") }
            }))
        defer { release.signal() }
        try await fixture.until { FileManager.default.fileExists(atPath: fixture.record.path) }
        renderer.retire(cancel: true)
        await #expect(throws: OwnedReplyRendererError.cleanupDeferred) { try await renderer.waitForCleanup() }
        try await fixture.until { reached.withLock { $0 } }
        #expect(renderer.isRunning)
        #expect(!renderer.cleanupComplete)
        release.signal()
        await renderer.waitForCancellationSignals()
        try await fixture.until { !renderer.isRunning }
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
    }

    @Test func checkToDeleteLeafReplacementPreservesUnrelatedContents() async throws {
        let fixture = try RendererFixture(mode: "normal")
        defer { fixture.remove() }
        let original = fixture.outputRoot.appendingPathComponent("retained-original")
        let replaced = Mutex<URL?>(nil)
        let renderer = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
            environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(cleanup: {
                do {
                    let leaf = try FileManager.default.contentsOfDirectory(at: fixture.outputRoot,
                        includingPropertiesForKeys: nil)[0]
                    try FileManager.default.moveItem(at: leaf, to: original)
                    try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
                    try Data("unrelated".utf8).write(to: leaf.appendingPathComponent("preserve"))
                    replaced.withLock { $0 = leaf }
                } catch { Issue.record("synthetic replacement setup failed") }
            }))
        try await fixture.until { !renderer.isRunning }
        renderer.retire(cancel: false)
        await #expect(throws: OwnedReplyRendererError.cleanupFailed) { try await renderer.waitForCleanup() }
        let replacement = try #require(replaced.withLock { $0 })
        #expect(try String(contentsOf: replacement.appendingPathComponent("preserve"), encoding: .utf8) == "unrelated")
        #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("synthetic.raw").path))
    }

    @Test func checkToDeleteRootReplacementCannotRedirectRecursiveCleanup() async throws {
        let fixture = try RendererFixture(mode: "normal")
        defer { fixture.remove() }
        let original = fixture.base.appendingPathComponent("retained-root")
        let renderer = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
            environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(cleanup: {
                do {
                    try FileManager.default.moveItem(at: fixture.outputRoot, to: original)
                    try FileManager.default.createDirectory(at: fixture.outputRoot, withIntermediateDirectories: false)
                    try Data("unrelated".utf8).write(to: fixture.outputRoot.appendingPathComponent("preserve"))
                } catch { Issue.record("synthetic replacement setup failed") }
            }))
        try await fixture.until { !renderer.isRunning }
        renderer.retire(cancel: false)
        await #expect(throws: OwnedReplyRendererError.cleanupFailed) { try await renderer.waitForCleanup() }
        #expect(try String(contentsOf: fixture.outputRoot.appendingPathComponent("preserve"), encoding: .utf8)
                == "unrelated")
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.path).count == 1)
    }

    @Test func cleanupUnlinksSymlinksWithoutFollowingAndRemovesOnlyOwnedNestedContents() async throws {
        let fixture = try RendererFixture(mode: "normal")
        defer { fixture.remove() }
        let renderer = try fixture.start()
        try await fixture.until { !renderer.isRunning }
        let nested = renderer.outputDirectory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let protected = fixture.base.appendingPathComponent("protected")
        try Data("unrelated".utf8).write(to: protected)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("link"),
                                                  withDestinationURL: protected)
        renderer.retire(cancel: false)
        try await renderer.waitForCleanup()
        #expect(try String(contentsOf: protected, encoding: .utf8) == "unrelated")
        #expect(!FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
    }

    @Test func cancelledLeaderDoesNotPretendItsOrdinaryDescendantStoppedWriting() async throws {
        let fixture = try RendererFixture(mode: "descendant-writer")
        defer { fixture.remove() }
        let renderer = try fixture.start()
        try await fixture.until { FileManager.default.fileExists(atPath: fixture.record.path) }
        renderer.retire(cancel: true)
        await #expect(throws: OwnedReplyRendererError.cleanupDeferred) { try await renderer.waitForCleanup() }
        #expect(renderer.cleanupDisposition == .deferred)
        try await fixture.until { !renderer.isRunning }
        try await fixture.until { FileManager.default.fileExists(atPath: fixture.record.path + ".done") }
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory
            .appendingPathComponent("late-descendant.raw").path))
        #expect(!renderer.cleanupComplete)
    }
}
#endif
