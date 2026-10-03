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
    struct Rig {
        let rig: RecipientTestRig
        let listener: WebSocketListener
        let router: AmbientRightyoRouter
        let connected: ConnectedPeerIDs
        let port: UInt16
    }

    func start(_ fake: FakeRightyo, timing: RightyoChildProcess.Timing) async throws -> Rig {
        let rig = try await RecipientTestRig.make()
        let connected = ConnectedPeerIDs()
        let router = AmbientRightyoRouter(configuration: .init(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target,
            binding: "reply-binding", allowSynthetic: true, timing: timing
        ))
        // No idle sweeper: only the frame, the disconnect or the stop under test can end a stream.
        let gate = AmbientAudioGate(target: RecipientTestRig.target, sink: router, sweepInterval: nil)
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(ambientAudio: gate), hostName: "mac-test",
            singleTerminalReplyFallback: true, ambient: router, log: { connected.record($0) }
        )
        return Rig(rig: rig, listener: listener, router: router, connected: connected,
                   port: try await listener.start())
    }

    func audio(_ stream: UUID, _ sequence: Int, final: Bool = false) -> Frame {
        sessionFrame(target: RecipientTestRig.target,
                     payload: .audio(ambientSegment(stream: stream, sequence: sequence, isFinal: final)))
    }

    func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func audioReachesTheChildAndItsRequestIsDispatchedForThatPeer() async throws {
        let fake = try FakeRightyo("""
            /usr/bin/wc -c | /usr/bin/tr -d ' ' > stdin-bytes.txt
            /usr/bin/sed "s/tool-demo/$7/g" events.jsonl
            """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await start(fake, timing: .init(eofGrace: 20, termGrace: 20))
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
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func disconnectStopsAndReapsTheChild() async throws {
        // Ignores stdin EOF, so only the stop's signals end it.
        let fake = try FakeRightyo("echo $$ > pid.txt\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let env = try await start(fake, timing: .init(eofGrace: 0.2, termGrace: 5))
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

    @Test func aSecondDeviceIsToldAmbientIsBusy() async throws {
        let fake = try FakeRightyo("exec /bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await start(fake, timing: .init(eofGrace: 5, termGrace: 5))
        let pair = try await FallbackSocketPair.connect(
            port: env.port, selecting: [RecipientTestRig.target, RecipientTestRig.target]
        )
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        try await pair.barrier()
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[1])
        let refusal = try await recipientSocketReceive(on: pair.sockets[1])
        #expect(refusal.payload == .control(.error(code: .notAllowed, message: "ambient busy")))
        #expect(env.router.liveRuns == 1)
        await env.listener.stop(reason: "synthetic test complete")
        #expect(env.router.liveRuns == 0)
    }

    /// The #212 constraint: daemon stop reaps the child but never cancels a run mid-dispatch; it waits.
    @Test func daemonStopWaitsForAnInFlightDispatchToFinish() async throws {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await start(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
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

@Suite(.timeLimit(.minutes(1))) struct AmbientStartupValidationTests {
    @Test func startupPinsTheListedBindingAndRefusesUnknownTargetsAndUnsafeExecutables() async throws {
        let rig = try await RecipientTestRig.make()
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let options = ConnectionProbeDaemon.AmbientOptions(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target
        )
        let router = try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: { _ in })
        #expect(router.configuration.binding == "reply-binding")
        #expect(!router.configuration.allowSynthetic)
        var unknown = options
        unknown.target = "recipient:missing"
        await #expect(throws: HostError.unknownTarget("recipient:missing")) {
            try await ConnectionProbeDaemon.ambientRouter(unknown, host: rig.host, log: { _ in })
        }
        let writable = try FakeRightyo("exit 0", mode: 0o775)
        defer { writable.cleanUp() }
        var unsafe = options
        unsafe.executable = writable.executable
        await #expect(throws: RightyoChildError.unsafeExecutable) {
            try await ConnectionProbeDaemon.ambientRouter(unsafe, host: rig.host, log: { _ in })
        }
    }
}
#endif
