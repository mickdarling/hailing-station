#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Loopback proof of #203 wiring: phone audio frames reach a fake `rightyo` child, its admitted request is
/// dispatched in process on behalf of the streaming peer, and teardown reaps the child without cancelling a run.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringTests {
    @Test func audioReachesTheChildItsRequestIsDispatchedForThatPeerAndRepliesReachIt() async throws {
        let fake = try FakeRightyo(ambientEchoAtEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let auditDirectory = fake.directory.appendingPathComponent("audit")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20),
                                       audit: AuditLog(directory: auditDirectory))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        for sequence in 0..<3 {
            try await recipientSocketSend(audio(stream, sequence, final: sequence == 2), on: pair.sockets[0])
        }
        try await pair.barrier()
        await env.router.settle()
        #expect(try fake.recorded("stdin-bytes.txt") == "9600\n")
        let contexts = await env.rig.adapter.contexts
        try #require(contexts.count == 1)
        let id = try #require(env.connected.all.first)
        let peer = try #require(await env.listener.peers[id])
        let connection = await peer.session.connectionID
        #expect(contexts[0].connectionID == connection)
        #expect(env.router.liveRuns == 0)
        // The audit names the tool, target and size, never the prompt.
        let history = try AuditHistory(directory: auditDirectory).today()
        #expect(history.filter { $0.contains("ambient-dispatch") }.count == 1)
        #expect(!history.contains { $0.contains("discussion") })
        // A clean run after a final segment sends no error; the owned reply and the fallback reply both arrive.
        let owned = recipientText(recipientDescriptor(contexts[0]))
        #expect(try await env.listener.publish(owned) == 1)
        #expect(try await recipientSocketReceive(on: pair.sockets[0]) == owned)
        let fallback = Frame(timestamp: 1, target: RecipientTestRig.target, source: "mac-test",
                             payload: .text(TextPayload(text: "synthetic response", reply: uncorrelatedDescriptor())))
        #expect(try await env.listener.publish(fallback) == 1)
        #expect(try await recipientSocketReceive(on: pair.sockets[0]) == fallback)
        try await pair.barrier()
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func theSameConnectionCanStartANewStreamAfterOneEnds() async throws {
        let fake = try FakeRightyo(ambientEchoAtEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        for round in 1...2 {
            let stream = UUID()
            try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
            try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
            try await pair.barrier()
            await env.router.settle()
            #expect(try fake.recorded("stdin-bytes.txt") == "6400\n")
            #expect(await env.rig.adapter.contexts.count == round)
        }
        try await pair.barrier()
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func disconnectStopsAndReapsTheChild() async throws {
        // Ignores stdin EOF, so only the stop's signals end it.
        let fake = try FakeRightyo("echo $$ > pid.txt\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 5))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        try await pair.barrier()
        #expect(env.router.liveRuns == 1)
        #expect(await eventually { (try? fake.recorded("pid.txt")) != nil })
        let pid = try #require(Int32(try fake.recorded("pid.txt").trimmingCharacters(in: .whitespacesAndNewlines)))
        pair.close()
        #expect(await eventually { env.router.liveRuns == 0 })
        errno = 0
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await env.listener.stop(reason: "synthetic test complete")
    }

    /// The #212 constraint: daemon stop reaps the child but never cancels a run mid-dispatch; it waits.
    @Test func daemonStopWaitsForAnInFlightDispatchToFinish() async throws {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        await env.rig.adapter.holdHandoff()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        try await pair.barrier()
        await env.rig.adapter.waitForHandoff()
        let stopped = Mutex(false)
        let stopping = Task {
            await env.listener.stop(reason: "synthetic stop")
            stopped.withLock { $0 = true }
        }
        try await Task.sleep(for: .seconds(1))
        #expect(!stopped.withLock { $0 })
        #expect(env.router.liveRuns == 1)
        await env.rig.adapter.releaseHandoff()
        await stopping.value
        #expect(await env.rig.adapter.contexts.count == 1)
        #expect(env.router.liveRuns == 0)
    }
}

#endif
