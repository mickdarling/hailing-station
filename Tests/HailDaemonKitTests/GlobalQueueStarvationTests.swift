#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #980: haild's safety timeouts and exit notifications still fire on time while `DispatchQueue.global()` is starved.
/// That root queue is not overcommit: libdispatch runs its blocks only on the process's constrained workers, and on a
/// small, busy CI runner every one of them was taken, so a block queued there ran about 11 s late (#979). Each test
/// parks every constrained worker, runs one safety path, and requires it to finish well inside the hold. On the
/// global queue the path cannot finish before the hold ends, so the bound fails. Forced blocking, never CPU load.
/// The suites starve the whole process, so they run one at a time, and each is named for its family so verify.sh
/// runs it in the serial timing lane (#208), never beside the parallel lane.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct GlobalQueueStarvationTests {
    /// Post-saturation hold; released as soon as the path under test returns. Setup also parks workers for up to
    /// 10 s plus a 300 ms canary check: nominal total 18.3 s, plus enqueue and scheduling overhead.
    static let hold: Duration = .seconds(8)
    /// Each path's graces add up to well under a second; half the hold leaves a loaded runner its margin.
    static let bound: Duration = .seconds(4)
}

extension GlobalQueueStarvationTests {
    /// The exit wait's timeouts, and `stop()`'s EOF, SIGTERM and SIGKILL escalation on them.
    @Suite struct RightyoChildProcessTimeouts {
        @Test func aRightyoExitWaitTimesOutOnTime() async throws {
            let latch = RightyoExitLatch()
            let (exit, elapsed) = try await whileGlobalQueueStarved { await latch.wait(timeout: 0.2) }
            #expect(exit == nil)
            #expect(elapsed < GlobalQueueStarvationTests.bound, "exit wait took \(elapsed)")
        }

        @Test func aRightyoChildIgnoringEOFAndTERMIsKilledOnTime() async throws {
            let fake = try FakeRightyo("trap '' TERM\n: > ready.txt\nexec /bin/sleep 60")
            defer { fake.cleanUp() }
            let child = try fake.child(.init(eofGrace: 0.2, termGrace: 0.2))
            try #require(await eventually { (try? fake.recorded("ready.txt")) != nil })
            let (exit, elapsed) = try await whileGlobalQueueStarved { await child.stop() }
            #expect(exit == .signaled(SIGKILL))
            #expect(elapsed < GlobalQueueStarvationTests.bound, "stop took \(elapsed)")
        }
    }

    /// Daemon stop's drain grace ends the wait for a run stuck in its dispatch.
    @Suite struct AmbientWiringDrainGrace {
        @Test func theRoutersDrainGraceEndsOnTime() async throws {
            let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
            defer { fake.cleanUp() }
            try fake.install(fixture: "tool-events.jsonl")
            let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1), shutdownGrace: 0.5)
            await env.rig.adapter.holdHandoff()
            let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
            defer { pair.close() }
            try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
            try await pair.boundedBarrier(step: "segment before stop")
            await env.rig.adapter.waitForHandoff()
            let listener = env.listener
            let (_, elapsed) = try await whileGlobalQueueStarved { await listener.stop(reason: "synthetic stop") }
            #expect(elapsed < GlobalQueueStarvationTests.bound, "daemon stop took \(elapsed)")
            // The grace ended the wait, not the run: it is still there until its handoff returns.
            #expect(env.router.liveRuns == 1)
            await env.rig.adapter.releaseHandoff()
            #expect(await eventually { env.router.liveRuns == 0 })
        }
    }

    /// The Codex probe's path (#931): SIGTERM, SIGKILL after the grace, then the join.
    @Suite struct OwnedStdioChildGrace {
        @Test func aStdioChildIgnoringTERMIsKilledAndJoinedOnTime() async throws {
            let child = try OwnedStdioChild(command: CodexStdioFixtures.command(
                #"$SIG{TERM}='IGNORE'; print "ready\n"; while(1) { select undef,undef,undef,1; }"#), grace: 0.1)
            defer { child.cancel() }
            #expect(try await CodexStdioFixtures.firstChunk(child) == Data("ready\n".utf8))
            let (_, elapsed) = try await whileGlobalQueueStarved {
                child.cancel()
                await child.join()
            }
            #expect(child.isReaped)
            #expect(elapsed < GlobalQueueStarvationTests.bound, "cancel and join took \(elapsed)")
        }
    }

    /// The reply renderer's SIGKILL escalation, exit, signal and cleanup waits.
    @Suite struct OwnedReplyRendererEscalation {
        @Test func aRendererIgnoringTERMIsKilledReapedAndRetiredOnTime() async throws {
            let fixture = try RendererFixture(mode: "ignore-term")
            defer { fixture.remove() }
            let renderer = try fixture.start()
            try await fixture.until("TERM-ignore fixture ready") {
                FileManager.default.fileExists(atPath: fixture.record.path)
            }
            let (outcome, elapsed) = try await whileGlobalQueueStarved {
                renderer.cancel()
                await renderer.waitForCancellationSignals()
                let exit = await Self.caught { try await renderer.requireSuccessfulExit() }
                renderer.retire(cancel: true)
                return (exit: exit, cleanup: await Self.caught { try await renderer.waitForCleanup() })
            }
            #expect(outcome.exit == .cancelled)
            #expect(outcome.cleanup == .cleanupDeferred)
            #expect(!renderer.isRunning)
            #expect(elapsed < GlobalQueueStarvationTests.bound, "cancel, exit and retirement took \(elapsed)")
        }

        private static func caught(_ body: () async throws -> Void) async -> OwnedReplyRendererError? {
            do { try await body() } catch let error as OwnedReplyRendererError { return error } catch {
                Issue.record("unexpected renderer error \(type(of: error))")
            }
            return nil
        }
    }
}

/// Runs `work` while every constrained dispatch worker is parked, and returns its result and how long it took. The
/// post-saturation hold ends once `work` returns or `hold` passes, whichever is first. Setup also parks workers for
/// up to 10 s plus a 300 ms canary check (plus enqueue/scheduling overhead). The pool is always released before this
/// returns. Work that needs the global queue takes at least `hold` after saturation.
func whileGlobalQueueStarved<T: Sendable>(
    hold: Duration = GlobalQueueStarvationTests.hold, _ work: @escaping @Sendable () async throws -> T
) async throws -> (value: T, elapsed: Duration) {
    let pool = ConstrainedPoolSaturation()
    defer { pool.release() }
    let parked = await pool.park()
    try #require(parked.saturated, "constrained pool not saturated: \(parked.running) workers parked")
    let started = ContinuousClock.now
    let task = Task { () async throws -> (T, Duration) in
        defer { pool.finished() }
        let value = try await work()
        return (value, started.duration(to: .now))
    }
    while !pool.isFinished, started.duration(to: .now) < hold { try await Task.sleep(for: .milliseconds(10)) }
    pool.release()
    let (value, elapsed) = try await task.value
    return (value, elapsed)
}

/// Parks the process's constrained (non-overcommit) dispatch workers on one semaphore. Each parked block blocks, so
/// the kernel adds workers up to its constrained limit (`kern.wq_max_constrained_threads`, shared by every QoS) and
/// no more; twice that many are queued, so a worker freed by another suite takes a parked block, never one under
/// test. A labelled serial queue targets the overcommit root queue, which gets its own workers, and still runs.
final class ConstrainedPoolSaturation: Sendable {
    private struct State { var running = 0, canaries = 0, released = false, finished = false }
    private let gate = DispatchSemaphore(value: 0)
    private let state = Mutex(State())
    private let parked: Int

    init() {
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let read = sysctlbyname("kern.wq_max_constrained_threads", &limit, &size, nil, 0) == 0 && limit > 0
        parked = 2 * (read ? Int(limit) : 64)
    }

    /// Saturated once no further worker has started for 300 ms and canaries queued at default and utility QoS have
    /// still not run 300 ms later. Counts only.
    func park() async -> (saturated: Bool, running: Int) {
        for _ in 0..<parked {
            DispatchQueue.global().async { [self] in
                state.withLock { $0.running += 1 }
                gate.wait()
            }
        }
        var (last, steadySince) = (-1, ContinuousClock.now)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            let running = state.withLock { $0.running }
            if running != last {
                (last, steadySince) = (running, .now)
            } else if steadySince.duration(to: .now) >= .milliseconds(300) {
                break
            }
        }
        DispatchQueue.global().async { [self] in state.withLock { $0.canaries += 1 } }
        DispatchQueue.global(qos: .utility).async { [self] in state.withLock { $0.canaries += 1 } }
        try? await Task.sleep(for: .milliseconds(300))
        return state.withLock { ($0.canaries == 0 && $0.running < parked, $0.running) }
    }

    func finished() { state.withLock { $0.finished = true } }
    var isFinished: Bool { state.withLock { $0.finished } }

    /// Idempotent: every parked block, started or still queued, passes the gate.
    func release() {
        let first = state.withLock { state -> Bool in
            defer { state.released = true }
            return !state.released
        }
        if first { for _ in 0..<parked { gate.signal() } }
    }
}
#endif
