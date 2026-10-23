#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Regression guards for in-memory privacy (#735, Mick 2026-10-22): haild never starts capture or spawns RightyO
/// without a device's audio stream, and privacy never outlives its router: after a restart a new connection has no
/// privacy state and its first stream starts public. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyInMemoryTests {
    static let argv = "echo \"$*\" >> argv.txt\n" + FakeRightyo.ackingControl(append: true) + "\n"

    /// A device that connects and selects the target, but sends no audio, starts no capture and no child.
    @Test func noChildWithoutADeviceAudioStream() async throws {
        let fake = try FakeRightyo(Self.argv + AmbientPrivacyEntryTests.fixture(
            saying: "Rightyo, archive the project.", advertises: true))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let events = DuckEvents()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), replyControl: true,
                                       onEvent: { event in events.list.withLock { $0.append(event) } })
        let (session, socket) = try recipientSocket(port: env.port)
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [DuckMode.capability], deviceName: "test"
        )))), on: socket)
        _ = try await receiveFrame(on: socket, step: "host hello")
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await barrier(on: socket, step: "selection")
        try await Task.sleep(for: .milliseconds(500))
        #expect(env.router.liveRuns == 0 && env.router.activeStream == nil)
        #expect(!FileManager.default.fileExists(atPath: fake.directory.appendingPathComponent("argv.txt").path))
        #expect(events.list.withLock { $0.allSatisfy { !$0.event.hasPrefix("ambient_") } })
        await env.listener.stop(reason: "synthetic test complete")
    }

    /// Privacy in one router never reaches the next: after a "restart" (a new router and listener), a new
    /// connection has no `duck` entry and its first stream's child is launched without `--start-private`.
    @Test func aRestartedRouterStartsPublic() async throws {
        let first = try await DuckRig(script: Self.argv + AmbientDuckReloadTests.entry)
        #expect(await eventually { first.details("ambient_duck").count == 1 })
        let before = try #require(first.connection())
        #expect(first.env.router.duckMode(connection: before))
        await first.finish()
        first.close()

        let quiet = Self.argv + AmbientPrivacyEntryTests.fixture(saying: "Rightyo, archive the project.",
                                                                 advertises: true)
        let second = try await DuckRig(script: quiet)
        defer { second.close() }
        #expect(await eventually {
            (try? second.fake.recorded("argv.txt"))?.split(separator: "\n").count == 1
        })
        let connection = try #require(second.connection())
        #expect(connection != before)
        #expect(!second.env.router.duckMode(connection: connection))
        #expect(!second.env.router.duckMode(connection: before))
        #expect(try second.fake.recorded("argv.txt").contains("--start-private") == false)
        #expect(second.details("ambient_duck").isEmpty && second.details("ambient_duck_device").isEmpty)
        await second.finish()
    }
}
#endif
