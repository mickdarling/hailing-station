#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #405: a reload whose new child fails, cannot launch, or finds no free slot. Synthetic only (fake `rightyo`).
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringReloadFailureTests {
    /// A new install that dies at once ends the stream as any failed child does, and its failure, not the reload,
    /// is the last ambient event `haild doctor` reads.
    @Test func aNewChildThatFailsAtOnceLeavesItsFailureLast() async throws {
        let fake = try FakeRightyo("exec /bin/sleep 60")
        defer { fake.cleanUp() }
        let order = Mutex<[String]>([])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 0.2)) { event in
            guard event.event.hasPrefix("ambient_") else { return }
            let replaced = (event.detail ?? "").hasPrefix("replaced ")
            order.withLock { $0.append(event.event + (replaced ? "(replaced)" : "")) }
        }
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        try await pair.barrier()
        try rewriteFake(fake, "exit 0")
        #expect(await env.router.reload() == .reloaded)
        #expect(try await ambientError(on: pair.sockets[0]).hasPrefix("ambient stopped: "))
        await settle(env.router, step: "failed reload")
        let events = order.withLock { $0 }.filter { $0 != "ambient_ended(replaced)" }
        let reloaded = try #require(events.firstIndex(of: "ambient_reloaded"))
        #expect(events.last == "ambient_ended")
        #expect(reloaded < events.count - 1)
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func aRefusedLaunchKeepsTheOldChild() async throws {
        let fake = try FakeRightyo("/bin/cat > v1-audio.bin")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.5, termGrace: 0.5))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        try await pair.barrier()
        // A missing config is refused before anything launches.
        let moved = fake.directory.appendingPathComponent("config.moved")
        try FileManager.default.moveItem(at: fake.config, to: moved)
        let outcome = await env.router.reload()
        try FileManager.default.moveItem(at: moved, to: fake.config)
        guard case .refused(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return await env.listener.stop(reason: "synthetic test failed")
        }
        #expect(reason == "child unsafeConfig")
        #expect(env.router.liveRuns == 1)
        try await recipientSocketSend(audio(stream, 1), on: pair.sockets[0])
        try await pair.barrier()
        #expect(await eventually { fakeFileSize(fake, "v1-audio.bin") == 6_400 })
        #expect(await env.gate.activeStream == stream)
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func aReloadWaitsForAFreeChildSlot() async throws {
        // A child that ignores EOF and SIGTERM stays unreaped until SIGKILL, holding the second slot.
        let fake = try FakeRightyo("trap '' TERM\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 0.2))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        try await pair.barrier()
        #expect(await env.router.reload() == .reloaded)
        #expect(await env.router.reload() == .busy)
        #expect(env.router.status().liveChildren == 2)
        #expect(await eventually { env.router.status().liveChildren == 1 })
        #expect(await env.router.reload() == .reloaded)
        try await pair.barrier()
        #expect(await env.gate.activeStream == stream)
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
