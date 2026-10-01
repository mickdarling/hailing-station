#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct OwnedReplyProcessIntegrationTests {
    @Test func lateCancellationAfterQuiescenceClaimCannotSignalOrRelabelNormalCleanup() async throws {
        let fixture = try PublisherFixture()
        let checkpoint = PublisherCheckpoint()
        let signals = Mutex<[Int32]>([])
        var hooks = OwnedReplyGroupHooks()
        hooks.beforeReap = { checkpoint.pause() }
        hooks.signal = { signal in signals.withLock { $0.append(signal) } }
        let publisher = try fixture.publisher(hooks: hooks)
        let task = Task { try await publisher.publish(fixture.reply()) }
        do {
            try await PublisherFixture.until { checkpoint.reached }
            task.cancel(); publisher.stop()
            #expect(signals.withLock { $0 } == [SIGCONT])
            #expect(publisher.diagnostics().retained == 1)
            checkpoint.resume()
            try await task.value
            try await fixture.shutdown(publisher)
            #expect(signals.withLock { $0 } == [SIGCONT])
        } catch {
            checkpoint.resume(); task.cancel(); _ = await task.result
            try await fixture.shutdown(publisher); throw error
        }
    }

    @Test func retiringOneGroupCannotSignalAnotherIndependentJob() async throws {
        let first = try PublisherFixture(mode: "ignore"), second = try PublisherFixture(mode: "ignore")
        let firstPublisher = try first.publisher(), secondPublisher = try second.publisher()
        let firstTask = Task { try await firstPublisher.publish(first.reply()) }
        let secondTask = Task { try await secondPublisher.publish(second.reply()) }
        do {
            try await PublisherFixture.until {
                FileManager.default.fileExists(atPath: first.record.path) &&
                    FileManager.default.fileExists(atPath: second.record.path)
            }
            firstTask.cancel()
            await #expect(throws: OwnedReplyPublisherError.cancelled) { try await firstTask.value }
            try await first.shutdown(firstPublisher)
            #expect(secondPublisher.diagnostics().retained == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: second.root.path).count == 1)
            secondTask.cancel(); _ = await secondTask.result
            try await second.shutdown(secondPublisher)
        } catch {
            firstTask.cancel(); secondTask.cancel()
            _ = await firstTask.result; _ = await secondTask.result
            try await first.shutdown(firstPublisher); try await second.shutdown(secondPublisher); throw error
        }
    }

    @Test func actualCLIAudioAckWaitRetiresWholeTERMignoringRendererGroupWithoutRetry() async throws {
        for cancellation in [true, false] {
            let fixture = try PublisherFixture(mode: "ignore", cli: true)
            let recorder = PublisherEndpointRecorder(blockAt: 2)
            let endpoint = try LocalReplyEndpoint(socketURL: fixture.base.appendingPathComponent("reply.sock"),
                                                 destination: recorder, audit: AuditLog(
                                                    directory: fixture.base.appendingPathComponent("audit")))
            try await endpoint.start()
            let publisher = try fixture.publisher(deadline: .seconds(1))
            let task = Task { try await publisher.publish(fixture.reply()) }
            do {
                try await PublisherFixture.until { await recorder.frames.count == 2 }
                if cancellation { task.cancel() }
                let expected: OwnedReplyPublisherError = cancellation ? .cancelled : .deadline
                await #expect(throws: expected) { try await task.value }
                #expect(await recorder.frames.count == 2)
                #expect(try String(contentsOf: fixture.record, encoding: .utf8) == "owned-cli-group-private-root")
                await recorder.release(); await endpoint.stop()
                try await fixture.shutdown(publisher)
            } catch {
                task.cancel(); _ = await task.result
                await recorder.release(); await endpoint.stop()
                try await fixture.shutdown(publisher); throw error
            }
        }
    }

    @Test func privateFolderRefusesReplacementAndDoesNotFollowExternalSymlink() throws {
        let fixture = try PublisherFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let directory = try OwnedReplyJobDirectory(root: fixture.root)
        let moved = fixture.root.appendingPathComponent("preserved")
        try FileManager.default.moveItem(at: directory.url, to: moved)
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        #expect(!directory.remove())
        try FileManager.default.removeItem(at: directory.url)
        try FileManager.default.moveItem(at: moved, to: directory.url)
        let outside = fixture.base.appendingPathComponent("outside")
        try Data("synthetic".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("link"),
                                                  withDestinationURL: outside)
        #expect(directory.remove())
        #expect(try String(contentsOf: outside, encoding: .utf8) == "synthetic")
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test func queuedDeadlineRetiresCallerWithoutCreatingAFifthResource() async throws {
        let fixture = try PublisherFixture()
        let unknown = Mutex(true)
        var hooks = OwnedReplyGroupHooks()
        hooks.inventory = { leader in unknown.withLock { $0 } ? nil : OwnedReplyGroupJob.inventory(leader) }
        let publisher = try fixture.publisher(deadline: .milliseconds(300), hooks: hooks)
        var tasks = (1...4).map { index in Task { try await publisher.publish(fixture.reply(index)) } }
        do {
            try await PublisherFixture.until { publisher.diagnostics().failed == 4 }
            let queued = Task { try await publisher.publish(fixture.reply(5)) }
            tasks.append(queued)
            try await PublisherFixture.until { publisher.diagnostics().failed == 5 }
            await #expect(throws: OwnedReplyPublisherError.deadline) { try await queued.value }
            #expect(publisher.diagnostics().retained == 4 && publisher.diagnostics().queued == 0)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 4)
            unknown.withLock { $0 = false }
            for task in tasks { _ = await task.result }
            try await fixture.shutdown(publisher)
        } catch {
            unknown.withLock { $0 = false }; for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
            try await fixture.shutdown(publisher); throw error
        }
    }
}
#endif
