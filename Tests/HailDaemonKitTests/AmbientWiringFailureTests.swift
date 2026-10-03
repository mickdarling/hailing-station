#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #203 round 1: every ambient failure ends the stream at the gate and tells the phone with an `ambient`-prefixed
/// error on an open connection; daemon stop is bounded even when a dispatch never returns.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringFailureTests {
    @Test func aRefusedStartEndsTheStreamAndTellsThePeer() async throws {
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 1, termGrace: 1),
                                       executable: URL(fileURLWithPath: "/nonexistent/rightyo"))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        #expect(try await ambientError(on: pair.sockets[0]) == "ambient unavailable: child unsafeExecutable")
        #expect(await env.gate.activeStream == nil)
        #expect(env.router.liveRuns == 0)
        try await pair.barrier()
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func aRefusedDispatchMidStreamEndsTheStreamAndTellsThePeer() async throws {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 2))
        await env.rig.adapter.failHandoff()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        let message = try await ambientError(on: pair.sockets[0])
        #expect(message.hasPrefix("ambient stopped: dispatch "))
        #expect(await env.gate.activeStream == nil)
        #expect(env.router.liveRuns == 0)
        // The connection stays open and the next segment of the ended stream is refused, not silently dropped.
        try await recipientSocketSend(audio(stream, 1), on: pair.sockets[0])
        #expect(try await ambientError(on: pair.sockets[0], code: .malformed).hasPrefix("ambient stream must be new"))
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func aChildThatExitsWhileTheStreamIsOpenEndsItAndTellsThePeer() async throws {
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 1, termGrace: 1))
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        #expect(try await ambientError(on: pair.sockets[0]).hasPrefix("ambient stopped: "))
        #expect(await env.gate.activeStream == nil)
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func daemonStopIsBoundedWhenADispatchNeverReturns() async throws {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1), shutdownGrace: 0.5)
        await env.rig.adapter.holdHandoff()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        try await pair.barrier()
        await env.rig.adapter.waitForHandoff()
        let started = ContinuousClock.now
        await env.listener.stop(reason: "synthetic stop")
        #expect(ContinuousClock.now - started < .seconds(10))
        // The stuck run was abandoned by the wait, not cancelled: it is still there until its handoff returns.
        #expect(env.router.liveRuns == 1)
        await env.rig.adapter.releaseHandoff()
        #expect(await eventually { env.router.liveRuns == 0 })
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
        // The reply block quotes the target, so an unsafe id refuses startup instead of every stream.
        var quoted = options
        quoted.target = "recipient:reply; rm"
        await #expect(throws: RightyoTargetError.unsafeIdentifier) {
            try await ConnectionProbeDaemon.ambientRouter(quoted, host: rig.host, log: { _ in })
        }
    }
}
#endif
