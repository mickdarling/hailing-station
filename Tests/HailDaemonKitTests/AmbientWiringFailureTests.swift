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

    @Test func aChildThatDiesDuringAStuckDispatchEndsTheStreamOnTheNextSegment() async throws {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\n: > exited.txt")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 1, termGrace: 1))
        await env.rig.adapter.holdHandoff()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        await env.rig.adapter.waitForHandoff()
        #expect(await eventually { (try? fake.recorded("exited.txt")) != nil })
        try await Task.sleep(for: .milliseconds(200))
        // The run is stuck in the held dispatch; the child is gone, so its input refuses audio.
        for sequence in 1...20 {
            try await recipientSocketSend(audio(stream, sequence), on: pair.sockets[0])
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await ambientError(on: pair.sockets[0]) == "ambient stopped: listener input closed")
        #expect(await env.gate.activeStream == nil)
        #expect(env.router.liveRuns == 1)
        await env.rig.adapter.releaseHandoff()
        #expect(await eventually { env.router.liveRuns == 0 })
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

/// #203: a late failure reaches the phone only while no newer stream has started on its connection: a
/// normally ended stream still dispatching after EOF is reported, a superseded one is not.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringLateFailureTests {
    @Test func aSupersededStreamsLateFailureIsNotReportedAgainstTheCurrentStream() async throws {
        // The first child emits a request and idles; every later child just idles.
        let fake = try FakeRightyo("""
            if [ -e first ]; then exec /bin/sleep 60; fi
            : > first
            /usr/bin/sed "s/tool-demo/$7/g" events.jsonl
            exec /bin/sleep 60
            """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 2))
        await env.rig.adapter.holdHandoff()
        await env.rig.adapter.failHandoff()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        await env.rig.adapter.waitForHandoff()
        let current = UUID()
        try await recipientSocketSend(audio(current, 0), on: pair.sockets[0])
        try await pair.barrier()
        #expect(await env.gate.activeStream == current)
        // The old stream's dispatch is now refused; its run fails after the replacement started.
        await env.rig.adapter.releaseHandoff()
        #expect(await eventually { env.router.liveRuns == 1 })
        try await pair.barrier()
        #expect(await env.gate.activeStream == current)
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func aNormallyEndedStreamsLateDispatchFailureIsStillReported() async throws {
        let fake = try FakeRightyo(ambientEchoAtEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20))
        await env.rig.adapter.failHandoff()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        // The final segment ends the stream at the gate; the child dispatches only after its input closes.
        try await recipientSocketSend(audio(UUID(), 0, final: true), on: pair.sockets[0])
        #expect(try await ambientError(on: pair.sockets[0]).hasPrefix("ambient stopped: dispatch "))
        #expect(await env.gate.activeStream == nil)
        #expect(await eventually { env.router.liveRuns == 0 })
        try await pair.barrier()
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func aNormallyEndedStreamsLateFailureIsNotReportedOnceAReplacementStarted() async throws {
        // The first child dispatches after its input closes; every later child just idles.
        let fake = try FakeRightyo("""
            if [ -e first ]; then exec /bin/sleep 60; fi
            : > first
            /usr/bin/wc -c > /dev/null
            /usr/bin/sed "s/tool-demo/$7/g" events.jsonl
            """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 2))
        await env.rig.adapter.holdHandoff()
        await env.rig.adapter.failHandoff()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0, final: true), on: pair.sockets[0])
        await env.rig.adapter.waitForHandoff()
        let current = UUID()
        try await recipientSocketSend(audio(current, 0), on: pair.sockets[0])
        try await pair.barrier()
        #expect(await env.gate.activeStream == current)
        // The ended stream's dispatch is now refused after the replacement started: logged, not reported.
        await env.rig.adapter.releaseHandoff()
        #expect(await eventually { env.router.liveRuns == 1 })
        try await pair.barrier()
        #expect(await env.gate.activeStream == current)
        await env.listener.stop(reason: "synthetic test complete")
    }
}
#endif
