import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #614: the shared host health service (#661 review and its follow-up): one evaluation per window shared by every
/// request, a stale result answered at once while one refresh runs, a deadline with a minimal report, and the daemon
/// version pinned to the wire pattern.
@Suite struct HostHealthServiceTests {
    static let minimal = HostHealth(version: "0.1.0", build: nil, checks: [.init(name: "daemon_running", ok: true)])
    static let report = HostHealth(version: "0.1.0", build: "0123456789abcdef", checks: [
        .init(name: "daemon_running", ok: true), .init(name: "listener_ready", ok: false)
    ])

    /// The #661 review: any number of concurrent requests cost one evaluation, every one is answered, and a repeat
    /// inside the window is answered from the cache; only once the window has passed does a request evaluate again.
    @Test func concurrentRequestsShareOneEvaluationAndRepeatsAreCached() async {
        let evaluations = Mutex(0), clock = Mutex(ContinuousClock.now)
        let service = HostHealthService(ttl: .seconds(30), now: { clock.withLock { $0 } }, fallback: Self.minimal,
                                        evaluate: {
            evaluations.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.2) // slow, as the real audit verify is
            return Self.report
        })
        let answers = await withTaskGroup(of: HostHealth.self) { group in
            for _ in 0..<64 { group.addTask { await service.current() } }
            return await group.reduce(into: [HostHealth]()) { $0.append($1) }
        }
        #expect(answers.count == 64 && answers.allSatisfy { $0 == Self.report })
        #expect(evaluations.withLock { $0 } == 1)
        clock.withLock { $0 += .seconds(29) }
        #expect(await service.current() == Self.report && evaluations.withLock { $0 } == 1)
        clock.withLock { $0 += .seconds(2) }
        // Stale: answered at once from the cache while one refresh runs.
        #expect(await service.current() == Self.report)
        #expect(await eventually { evaluations.withLock { $0 } == 2 })
    }

    /// The follow-up to #661 review: a stale result is answered at once while the refresh runs, and with nothing
    /// cached a request waits at most the deadline, then gets the minimal report; the stuck evaluation is never
    /// started twice. So a slow doctor run never holds up the connection's other frames.
    @Test func aSlowEvaluationNeverBlocksARequest() async {
        let evaluations = Mutex(0), release = DispatchSemaphore(value: 0)
        let service = HostHealthService(ttl: .seconds(30), deadline: .milliseconds(100), fallback: Self.minimal,
                                        evaluate: {
            evaluations.withLock { $0 += 1 }
            release.wait() // stuck until released
            return Self.report
        })
        let started = ContinuousClock.now
        #expect(await service.current() == Self.minimal)
        #expect(await service.current() == Self.minimal)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(evaluations.withLock { $0 } == 1) // the stuck one stays in flight, never restarted
        release.signal()
        #expect(await eventually { await service.current() == Self.report })
        #expect(evaluations.withLock { $0 } == 1)
    }

    @Test func aStaleResultIsAnsweredWhileTheRefreshRuns() async {
        let clock = Mutex(ContinuousClock.now), calls = Mutex(0), release = DispatchSemaphore(value: 0)
        let fresh = HostHealth(version: "0.1.0", build: nil, checks: [.init(name: "daemon_running", ok: false)])
        let service = HostHealthService(ttl: .seconds(30), deadline: .seconds(30), now: { clock.withLock { $0 } },
                                        fallback: Self.minimal, evaluate: {
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if call > 1 { release.wait() }
            return call == 1 ? Self.report : fresh
        })
        #expect(await service.current() == Self.report)
        clock.withLock { $0 += .seconds(31) }
        let started = ContinuousClock.now
        #expect(await service.current() == Self.report) // stale, at once, though the refresh is stuck
        #expect(ContinuousClock.now - started < .seconds(1))
        release.signal()
        #expect(await eventually { await service.current() == fresh })
        #expect(calls.withLock { $0 } == 2)
    }

    /// The version goes on the wire under a fixed pattern; a release version outside it would make every report
    /// fail to encode, so this pins the two together.
    @Test func theDaemonVersionFitsTheWirePattern() throws {
        #expect(DaemonInfo.version.wholeMatch(of: /[0-9A-Za-z.+\-]{1,32}/) != nil)
        let report = HostHealthSummary.fallback(build: nil)
        #expect(report.version == DaemonInfo.version)
        _ = try FrameCoding.encode(Frame(timestamp: 1, source: "host", payload: .control(.healthReport(report))))
    }
}
