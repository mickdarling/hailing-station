import Dispatch
import Foundation
public import HailProtocol
import Synchronization

/// The `haild doctor` report (#247) reduced to what a device may see (#614): the release version, the build digest
/// and each known check's name and outcome. The detail and fix stay on the Mac (they can name paths, ports and
/// identities); the device points to `haild doctor` for them.
public enum HostHealthSummary {
    /// The doctor's evaluation as this daemon sees itself: `build` (computed once at startup) and its host ID against
    /// its status file, its audit refusals and history. Slow (it verifies the whole audit history), so it is called
    /// only through `HostHealthService`, off the cooperative pool and at most once per cache window.
    static func evaluate(build: String?) -> HostHealth {
        var refusals: RefusalSummary?
        var auditUnreadable = false
        do {
            refusals = try RefusalSummary.read(from: AuditHistory.standard())
        } catch AuditHistoryError.noHistory {
            refusals = nil
        } catch {
            auditUnreadable = true
        }
        let report = HealthReport.evaluate(
            cli: .init(version: DaemonInfo.version, build: build, hostID: try? HostIdentity.resolve()),
            daemon: DaemonStatus.read(from: DaemonStatus.standardFile()),
            refusals: refusals, auditUnreadable: auditUnreadable
        )
        return summary(of: report)
    }

    /// The minimal report for a request that could not wait for an evaluation: the daemon answering is running.
    static func fallback(build: String?) -> HostHealth {
        summary(of: HealthReport(cli: .init(version: DaemonInfo.version, build: build, hostID: nil), daemon: nil,
                                 checks: []))
    }

    /// Known check names only, each once, at most `HostHealth.maxChecks`; a build that is not a 16-digit lowercase
    /// ASCII hex digest is left off. Never empty: the daemon answering is itself running, so with nothing else left
    /// `daemon_running` passes.
    static func summary(of report: HealthReport) -> HostHealth {
        var seen: Set<String> = []
        var checks = report.checks.compactMap { check -> HostHealth.Check? in
            guard let name = HostHealth.checkName(check.name), seen.insert(name).inserted else { return nil }
            return HostHealth.Check(name: name, ok: check.outcome == .ok)
        }
        checks = Array(checks.prefix(HostHealth.maxChecks))
        if checks.isEmpty { checks = [HostHealth.Check(name: "daemon_running", ok: true)] }
        let build = (report.daemon?.build ?? report.cli.build).flatMap { build in
            build.count == 16 && build.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
                ? build : nil
        }
        return HostHealth(version: report.cli.version, build: build, checks: checks)
    }
}

/// One shared health summary for every connection (#614 review). A `health` request never waits on a slow doctor
/// evaluation: a result at most `ttl` old is answered as is; an older one is answered at once while a single refresh
/// runs in the background; with none yet, the request waits at most `deadline`, then gets a minimal report. Each
/// evaluation runs on its own low-priority queue, never the cooperative pool, and at most one is in flight, shared by
/// every request, so a stuck one is never restarted. The daemon's service starts its first evaluation when it is
/// created, so a request after startup normally finds a result; at worst a request waits `deadline`, never longer,
/// before the connection's other frames (ambient audio) continue. Any number of devices or repeats cost at most one
/// evaluation per window.
public final class HostHealthService: Sendable {
    public static let defaultTTL: Duration = .seconds(30)
    public static let defaultDeadline: Duration = .seconds(8)

    private struct State {
        var cached: (health: HostHealth, at: ContinuousClock.Instant)?
        var inFlight: Task<HostHealth, Never>?
    }

    private let state = Mutex(State())
    private let ttl: Duration
    private let deadline: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let evaluate: @Sendable () -> HostHealth
    /// What a request gets when no result arrives within `deadline`: the daemon answering is running.
    private let fallback: HostHealth
    private let queue = DispatchQueue(label: "hail.host-health", qos: .utility)

    /// `build` is computed once here, at startup, not on each request.
    public convenience init() {
        let build = BuildIdentity.current()
        self.init(fallback: HostHealthSummary.fallback(build: build)) { HostHealthSummary.evaluate(build: build) }
        prime()
    }

    /// Starts the first evaluation now, off the cooperative pool, so the first `health` request after startup does
    /// not wait for a cold one (#690 review).
    func prime() {
        state.withLock { state in
            if state.cached == nil, state.inFlight == nil { state.inFlight = startEvaluation() }
        }
    }

    init(ttl: Duration = defaultTTL, deadline: Duration = defaultDeadline,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, fallback: HostHealth,
         evaluate: @escaping @Sendable () -> HostHealth) {
        (self.ttl, self.deadline, self.now, self.fallback, self.evaluate) = (ttl, deadline, now, fallback, evaluate)
    }

    @Sendable public func current() async -> HostHealth {
        // One lock decides: a fresh result; a stale one, answered while one refresh runs; or none yet, waited for.
        let (cached, running) = state.withLock { state -> (HostHealth?, Task<HostHealth, Never>?) in
            if let cached = state.cached, now() - cached.at < ttl { return (cached.health, nil) }
            let running = state.inFlight ?? startEvaluation()
            state.inFlight = running
            return (state.cached?.health, running)
        }
        if let cached { return cached }
        guard let running else { return fallback }
        return await Self.first(of: running, or: fallback, after: deadline)
    }

    /// The evaluation stores its own result, so a refresh nobody waits for still lands in the cache.
    private func startEvaluation() -> Task<HostHealth, Never> {
        let (evaluate, queue) = (evaluate, queue)
        return Task { [weak self] in
            let health = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: evaluate()) }
            }
            self?.state.withLock { state in
                state.cached = (health, self?.now() ?? .now)
                state.inFlight = nil
            }
            return health
        }
    }

    /// `task`'s result if it arrives within `deadline`, else `fallback`; the task itself keeps running. The deadline
    /// fires from a Dispatch timer, not a task sleeping on the cooperative pool, so a busy pool cannot hold it back.
    private static func first(of task: Task<HostHealth, Never>, or fallback: HostHealth,
                              after deadline: Duration) async -> HostHealth {
        await withCheckedContinuation { continuation in
            let answered = Mutex(false)
            let answer: @Sendable (HostHealth) -> Void = { health in
                guard answered.withLock({ done in
                    defer { done = true }
                    return !done
                }) else { return }
                continuation.resume(returning: health)
            }
            let (seconds, attoseconds) = deadline.components
            let nanoseconds = Int(clamping: seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
                answer(fallback)
            }
            Task { answer(await task.value) }
        }
    }
}
