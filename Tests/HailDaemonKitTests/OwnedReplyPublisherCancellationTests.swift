#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct OwnedReplyPublisherCancellationTests {
    @Test func cancellationRacingInstallationRetainsResourceAndAdmissionBounds() async throws {
        let fixture = try PublisherFixture()
        let race = PublisherCancellationRace()
        let publisher = try fixture.publisher(deadline: .seconds(30), hooks: race.hooks())
        let first = Task { try await publisher.publish(fixture.reply()) }
        var tasks: [Task<Void, any Error>] = []
        do {
            try await PublisherFixture.until { race.installation.reached }
            DispatchQueue.global(qos: .utility).async {
                first.cancel()
                race.cancelReturned.withLock { $0 = true }
            }
            try await PublisherFixture.until { race.cancellation.reached }
            race.installation.resume()
            try await PublisherFixture.until { race.activation.reached }
            race.cancellation.resume()
            try await PublisherFixture.until { race.cancelReturned.withLock { $0 } }
            await #expect(throws: OwnedReplyPublisherError.cancelled) { try await first.value }
            #expect(publisher.diagnostics().retained == 1 && publisher.diagnostics().running == 1)
            #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
            tasks = (2...16).map { index in Task { try await publisher.publish(fixture.reply(index)) } }
            try await expectResourceBounds(publisher, fixture: fixture)
            race.activation.resume()
            for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
            #expect(publisher.diagnostics().retained == 4 && publisher.diagnostics().running == 4)
            race.unknown.withLock { $0 = false }
            try await fixture.shutdown(publisher)
        } catch {
            race.installation.resume(); race.cancellation.resume(); race.activation.resume()
            race.unknown.withLock { $0 = false }; first.cancel()
            _ = await first.result
            for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
            publisher.stop()
            try await PublisherFixture.until {
                (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty) == true
            }
            try await fixture.shutdown(publisher); throw error
        }
    }

    private func expectResourceBounds(_ publisher: OwnedReplyPublisher, fixture: PublisherFixture) async throws {
        try await PublisherFixture.until {
            let status = publisher.diagnostics()
            return status.running == 4 && status.queued == 12
        }
        #expect(publisher.diagnostics().retained == 4)
        await #expect(throws: OwnedReplyPublisherError.capacityExceeded) {
            try await publisher.publish(fixture.reply(17))
        }
        try await PublisherFixture.until {
            (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count) == 4
        }
    }
}

private final class PublisherCancellationRace: Sendable {
    let installation = PublisherCheckpoint()
    let cancellation = PublisherCheckpoint()
    let activation = PublisherCheckpoint()
    let unknown = Mutex(true)
    let cancelReturned = Mutex(false)

    func hooks() -> OwnedReplyGroupHooks {
        let installed = Mutex(0)
        let latched = Mutex(0)
        let activated = Mutex(0)
        var hooks = OwnedReplyGroupHooks()
        hooks.beforeInstall = {
            let first = installed.withLock { $0 += 1; return $0 == 1 }
            if first { self.installation.pause() }
        }
        hooks.afterCancellationLatch = {
            let first = latched.withLock { $0 += 1; return $0 == 1 }
            if first { self.cancellation.pause() }
        }
        hooks.beforeResume = {
            let first = activated.withLock { $0 += 1; return $0 == 1 }
            if first { self.activation.pause() }
        }
        hooks.inventory = { leader in self.unknown.withLock { $0 } ? nil : OwnedReplyGroupJob.inventory(leader) }
        return hooks
    }
}
#endif
