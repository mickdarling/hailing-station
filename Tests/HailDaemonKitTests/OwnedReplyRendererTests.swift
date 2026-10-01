#if os(macOS)
import Darwin
import Foundation
import Testing
import Synchronization
@testable import HailDaemonKit

@Suite("Owned reply renderer")
struct OwnedReplyRendererTests {
    @Test func childRuntimeRejectsIgnoredAutoReapedOrCustomSignalHandlersWithoutChangingProcessSignals() {
        let normal = unsafeBitCast(SIG_DFL, to: UInt.self)
        let ignored = unsafeBitCast(SIG_IGN, to: UInt.self)
        #expect(ReplyRendererChildIdentity.supportsOwnership(handler: normal, flags: 0))
        #expect(!ReplyRendererChildIdentity.supportsOwnership(handler: ignored, flags: 0))
        #expect(!ReplyRendererChildIdentity.supportsOwnership(handler: normal, flags: SA_NOCLDWAIT))
        #expect(!ReplyRendererChildIdentity.supportsOwnership(handler: normal + 2, flags: 0))
    }

    @Test func lostOwnershipPermanentlyCutsOffSignalsWithoutClaimingReapingSuccess() {
        var child = ReplyRendererChildIdentity(pid: 123)
        let lost = child.observe(result: -1, status: 0, error: ECHILD)
        #expect(lost)
        #expect(child.pid == nil)
        #expect(child.status == nil)
        #expect(child.ownershipLost)
        var signals = 0
        child.signalIfOwned { _ in signals += 1 }
        let revived = child.observe(result: 123, status: 0, error: 0)
        #expect(!revived)
        child.signalIfOwned { _ in signals += 1 }
        #expect(signals == 0)
    }

    @Test func interruptedObservationPreservesIdentityUntilSuccessfulReapingCutoff() {
        var child = ReplyRendererChildIdentity(pid: 123)
        let interrupted = child.observe(result: -1, status: 0, error: EINTR)
        let idle = child.observe(result: 0, status: 0, error: 0)
        #expect(!interrupted)
        #expect(!idle)
        var ownedSignals = 0
        child.signalIfOwned { pid in #expect(pid == 123); ownedSignals += 1 }
        #expect(ownedSignals == 1)
        let reaped = child.observe(result: 123, status: 0, error: 0)
        #expect(reaped)
        child.signalIfOwned { _ in ownedSignals += 1 }
        #expect(ownedSignals == 1)
        #expect(!child.ownershipLost)
        #expect(child.status == 0)
    }
}

extension OwnedReplyRendererTests {
    @Test func normalExitRetainsFilesUntilConsumerRetirement() async throws {
        let fixture = try RendererFixture(mode: "normal")
        defer { fixture.remove() }
        let renderer = try fixture.start()
        try await fixture.until("normal exit observed") { !renderer.isRunning }
        try await renderer.requireSuccessfulExit()
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
        #expect(!renderer.cleanupComplete)
        #expect(try String(contentsOf: fixture.record, encoding: .utf8) == "same-group-private-output")
        renderer.retire(cancel: false)
        try await fixture.until("normal cleanup completed") { renderer.cleanupComplete }
        try await renderer.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.outputRoot.path))
    }

    @Test func cancellationKillsOnlyOwnedTermIgnoringChildAndRetainsConsumerFiles() async throws {
        let fixture = try RendererFixture(mode: "ignore-term")
        defer { fixture.remove() }
        let renderer = try fixture.start()
        try await fixture.until("TERM-ignore fixture ready") {
            FileManager.default.fileExists(atPath: fixture.record.path)
        }
        renderer.cancel()
        try await fixture.until("cancelled child reaped") { !renderer.isRunning }
        await #expect(throws: OwnedReplyRendererError.cancelled) { try await renderer.requireSuccessfulExit() }
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
        #expect(!renderer.cleanupComplete)
        renderer.retire(cancel: true)
        await #expect(throws: OwnedReplyRendererError.cleanupDeferred) { try await renderer.waitForCleanup() }
        #expect(renderer.cleanupDisposition == .deferred)
        #expect(!renderer.cleanupComplete)
        #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
    }

    @Test func droppingFacadeRetiresRunningChildButDefersAbnormalDirectoryCleanup() async throws {
        let fixture = try RendererFixture(mode: "ignore-term")
        defer { fixture.remove() }
        let reaped = Mutex(false)
        var renderer: OwnedReplyRenderer? = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
            environment: fixture.environment,
            hooks: ReplyRendererLifecycleHooks(reaped: { reaped.withLock { $0 = true } }))
        let output = try #require(renderer).outputDirectory
        try await fixture.until("facade-drop fixture ready") {
            FileManager.default.fileExists(atPath: fixture.record.path)
        }
        renderer = nil
        try await fixture.until("dropped facade child reaped") { reaped.withLock { $0 } }
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputRoot.path).count == 1)
    }

    @Test func failedRendererRetainsVisibleFailureAndDefersCleanupAfterRetirement() async throws {
        for mode in ["nonzero", "missing"] {
            let fixture = try RendererFixture(mode: mode)
            defer { fixture.remove() }
            let renderer = try fixture.start()
            try await fixture.until("failed renderer reaped") { !renderer.isRunning }
            let expected: OwnedReplyRendererError = mode == "missing" ? .rendererUnavailable : .nonzeroExit
            await #expect(throws: expected) { try await renderer.requireSuccessfulExit() }
            renderer.retire(cancel: false)
            await #expect(throws: OwnedReplyRendererError.cleanupDeferred) { try await renderer.waitForCleanup() }
            #expect(renderer.cleanupDisposition == .deferred)
            #expect(FileManager.default.fileExists(atPath: renderer.outputDirectory.path))
        }
    }

    @Test func cancellationBeforeAndDuringStartupRetainsCleanupOwnership() async throws {
        let fixture = try RendererFixture(mode: "ignore-term")
        defer { fixture.remove() }
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { _ = try fixture.start() }
        }
        await before.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputRoot.path).isEmpty)
        let reaped = Mutex(false)
        let during = Task {
            #expect(throws: OwnedReplyRendererError.cancelled) {
                _ = try OwnedReplyRenderer(text: "synthetic", outputRoot: fixture.outputRoot,
                    environment: fixture.environment, hooks: ReplyRendererLifecycleHooks(startup: {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }, reaped: { reaped.withLock { $0 = true } }))
            }
        }
        _ = await during.value
        try await fixture.until("startup-cancelled child reaped") { reaped.withLock { $0 } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputRoot.path).count == 1)
    }

    @Test func invalidRootAndStartupConfigurationNeverCreateUnownedOutputs() throws {
        let fixture = try RendererFixture(mode: "normal")
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.outputRoot.path)
        #expect(throws: OwnedReplyRendererError.invalidOutputRoot) { _ = try fixture.start() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.outputRoot.path)
        let link = fixture.base.appendingPathComponent("output-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outputRoot)
        #expect(throws: OwnedReplyRendererError.invalidOutputRoot) {
            _ = try OwnedReplyRenderer(text: "synthetic", outputRoot: link, environment: fixture.environment)
        }
        #expect(throws: OwnedReplyRendererError.startupFailed) {
            _ = try OwnedReplyRenderer(text: "synthetic\0invalid", outputRoot: fixture.outputRoot,
                                      environment: fixture.environment)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outputRoot.path).isEmpty)
    }

    @Test func replacedLeafIsNotDeletedAndCleanupFailsVisibly() async throws {
        let fixture = try RendererFixture(mode: "normal")
        defer { fixture.remove() }
        let renderer = try fixture.start()
        try await fixture.until("replacement fixture exit observed") { !renderer.isRunning }
        let original = fixture.outputRoot.appendingPathComponent("original-owned-leaf")
        try FileManager.default.moveItem(at: renderer.outputDirectory, to: original)
        try FileManager.default.createDirectory(at: renderer.outputDirectory, withIntermediateDirectories: false)
        let unrelated = renderer.outputDirectory.appendingPathComponent("unrelated")
        try Data("preserved".utf8).write(to: unrelated)
        renderer.retire(cancel: false)
        await #expect(throws: OwnedReplyRendererError.cleanupFailed) { try await renderer.waitForCleanup() }
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
}

#endif
