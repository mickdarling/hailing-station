#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #405: `haild ambient reload` restarts the active stream's RightyO child host-side. The phone is never told: its
/// stream stays open at the gate and its audio reaches the new child. Synthetic only (fake `rightyo`, loopback).
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringReloadTests {
    /// The fake's behaviour now; every child launched from here on runs it (the old one keeps what it read).
    private func rewrite(_ fake: FakeRightyo, _ body: String) throws {
        try Data("\(body)\n".utf8).write(to: fake.directory.appendingPathComponent("behavior.sh"), options: .atomic)
    }

    private func size(_ fake: FakeRightyo, _ name: String) -> Int {
        let path = fake.directory.appendingPathComponent(name).path
        return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? -1
    }

    @Test func reloadSwapsToTheNewInstallWithoutTellingThePhone() async throws {
        // The old install records its audio, then exits non-zero once its input closes.
        let fake = try FakeRightyo("/bin/cat > v1-audio.bin\nexit 3")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let events = AmbientEventNames()
        let ended = Mutex<[String]>([])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 2, termGrace: 2), events: events) { event in
            if event.event == "ambient_ended" { ended.withLock { $0.append(event.detail ?? "") } }
        }
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        for sequence in 0..<5 { try await recipientSocketSend(audio(stream, sequence), on: pair.sockets[0]) }
        try await pair.barrier()
        #expect(await eventually { size(fake, "v1-audio.bin") == 16_000 })
        let before = env.router.status()
        try rewrite(fake, ambientEchoAtEOF)
        #expect(await env.router.reload() == .reloaded)
        #expect(await env.gate.activeStream == stream)
        #expect(env.router.activeStream == stream)
        // The replaced child's non-zero exit is logged, never sent to the phone.
        #expect(await eventually { env.router.liveRuns == 1 })
        try await Task.sleep(for: .milliseconds(200))
        try await pair.barrier()
        #expect(await env.gate.activeStream == stream)
        let after = env.router.status()
        #expect(after.streamSince == before.streamSince)
        #expect(try #require(after.childSince) > (try #require(before.childSince)))
        // The same stream's audio now reaches the new child, which dispatches for this peer as before.
        for sequence in 5..<8 {
            try await recipientSocketSend(audio(stream, sequence, final: sequence == 7), on: pair.sockets[0])
        }
        try await pair.barrier()
        await settle(env.router, step: "reloaded run")
        #expect(try fake.recorded("stdin-bytes.txt") == "9600\n")
        #expect(size(fake, "v1-audio.bin") == 16_000)
        #expect(await env.rig.adapter.contexts.count == 1)
        try await pair.barrier()
        expectBalanced(events.all, ended: ended.withLock { $0 })
        await env.listener.stop(reason: "synthetic test complete")
    }

    /// One reload: two starts and two ends, and the replaced child's end is marked, so `haild doctor` does not read
    /// it as a failure; the new child's is not.
    private func expectBalanced(_ names: [String], ended details: [String]) {
        #expect(names.filter { $0 == "ambient_started" }.count == 2)
        #expect(names.filter { $0 == "ambient_ended" }.count == 2)
        #expect(names.filter { $0 == "ambient_reloaded" }.count == 1)
        #expect(details.count == 2)
        #expect(details.first?.hasPrefix("replaced ") == true)
        #expect(details.last?.hasPrefix("delivered=1 ") == true)
    }

    @Test func reloadWhenIdleStartsNothing() async throws {
        let fake = try FakeRightyo("exec /bin/sleep 60")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 0.2))
        #expect(await env.router.reload() == .idle)
        let report = await env.listener.ambient(LocalAmbientRequest(action: .reload))
        #expect(report.outcome == .idle)
        #expect(!report.active)
        #expect(report.liveChildren == 0)
        #expect(env.router.liveRuns == 0)
        let status = await env.listener.ambient(LocalAmbientRequest(action: .status))
        #expect(status.outcome == .status)
        #expect(status.target == RecipientTestRig.target)
        #expect(status.installedAt != nil)
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func reloadDuringShutdownIsRefused() async throws {
        let fake = try FakeRightyo("exec /bin/sleep 60")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 0.2))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        try await pair.barrier()
        #expect(env.router.activeStream != nil)
        await env.router.shutdown()
        #expect(await env.router.reload() == .stopping)
        #expect(env.router.liveRuns == 0)
        await env.listener.stop(reason: "synthetic test complete")
        #expect(await env.listener.ambient(LocalAmbientRequest(action: .reload)).outcome == .stopping)
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
        #expect(await eventually { size(fake, "v1-audio.bin") == 6_400 })
        #expect(await env.gate.activeStream == stream)
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func aSegmentThatRacedToTheReplacedChildDoesNotEndTheStream() async throws {
        let fake = try FakeRightyo("exec /bin/sleep 60")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 0.2))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        try await pair.barrier()
        let old = try #require(env.router.activePipeline)
        #expect(await env.router.reload() == .reloaded)
        // As if a segment read the old child just before the swap and found its input closed after it.
        env.router.inputClosed(stream, pipeline: old)
        #expect(env.router.activeStream == stream)
        #expect(env.router.activePipeline !== old)
        try await pair.barrier()
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
