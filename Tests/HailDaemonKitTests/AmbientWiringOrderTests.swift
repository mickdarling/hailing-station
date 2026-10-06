#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// Ambient lifecycle events stay in order per run (#273), which the status recorder (#278) relies on.
@Suite struct AmbientWiringOrderTests {
    @Test func aChildThatExitsAtOnceStillLogsItsStartBeforeItsEnd() async throws {
        // #273: the run's own task emits `ambient_started`, so a fast exit can never log its end first.
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let events = AmbientEventNames()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 1, termGrace: 1), events: events)
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        #expect(await eventually { events.all.contains("ambient_ended") })
        let names = events.all
        let started = try #require(names.firstIndex(of: "ambient_started"))
        let ended = try #require(names.firstIndex(of: "ambient_ended"))
        #expect(started < ended)
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
