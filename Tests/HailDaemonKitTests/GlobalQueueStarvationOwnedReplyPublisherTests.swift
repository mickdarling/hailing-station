#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension GlobalQueueStarvationTests {
    /// #955: the real CLI's first reply must not wait for a free constrained worker to start its owned job.
    @Suite struct OwnedReplyPublisherStart {
        @Test func anOwnedReplyStartsAndPublishesOnTime() async throws {
            let fixture = try PublisherFixture(cli: true)
            let destination = PublisherEndpointRecorder(blockAt: 1)
            let endpoint = try LocalReplyEndpoint(socketURL: fixture.base.appendingPathComponent("reply.sock"),
                destination: destination, audit: AuditLog(directory: fixture.base.appendingPathComponent("audit")))
            let publisher = try fixture.publisher(deadline: .seconds(30))
            let (starts, start) = AsyncStream<Void>.makeStream()
            let publication = Task {
                for await _ in starts { try await publisher.publish(fixture.reply()) }
            }
            do {
                try await endpoint.start()
                let (_, elapsed) = try await whileGlobalQueueStarved {
                    start.yield(()); start.finish()
                    // Observe even a delayed start after the eight-second hold; the four-second bound gates it.
                    try await PublisherFixture.until(timeout: .seconds(12)) { await destination.frames.count == 1 }
                }
                print("step=first_reply elapsed_ms=\(elapsed / .milliseconds(1))")
                #expect(elapsed < GlobalQueueStarvationTests.bound, "first reply took \(elapsed)")
                await destination.release()
                try await publication.value
                await endpoint.stop()
                try await fixture.shutdown(publisher)
            } catch {
                start.finish(); publication.cancel()
                await destination.release()
                _ = await publication.result
                await endpoint.stop()
                try await fixture.shutdown(publisher)
                throw error
            }
        }
    }
}
#endif
