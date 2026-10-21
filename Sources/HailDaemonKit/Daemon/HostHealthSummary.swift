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

/// One shared health summary for every connection (#614 review): a `health` request is answered from a result at
/// most `ttl` old; when it is older, one evaluation runs, on its own low-priority queue rather than the cooperative
/// pool, and every request waiting meanwhile shares it. So any number of devices or repeats cost at most one doctor
/// evaluation per window, and every request is answered.
public final class HostHealthService: Sendable {
    public static let defaultTTL: Duration = .seconds(30)

    private struct State {
        var cached: (health: HostHealth, at: ContinuousClock.Instant)?
        var inFlight: Task<HostHealth, Never>?
    }

    private enum Either {
        case fresh(HostHealth)
        case wait(Task<HostHealth, Never>)
    }

    private let state = Mutex(State())
    private let ttl: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let evaluate: @Sendable () -> HostHealth
    private static let queue = DispatchQueue(label: "hail.host-health", qos: .utility)

    /// `build` is computed once here, at startup, not on each request.
    public convenience init() {
        let build = BuildIdentity.current()
        self.init { HostHealthSummary.evaluate(build: build) }
    }

    init(ttl: Duration = defaultTTL, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         evaluate: @escaping @Sendable () -> HostHealth) {
        (self.ttl, self.now, self.evaluate) = (ttl, now, evaluate)
    }

    @Sendable public func current() async -> HostHealth {
        // One lock decides: a fresh cached result, the evaluation already running, or a new one.
        let decision = state.withLock { state -> Either in
            if let cached = state.cached, now() - cached.at < ttl { return .fresh(cached.health) }
            if let running = state.inFlight { return .wait(running) }
            let evaluate = evaluate
            let running = Task<HostHealth, Never> {
                await withCheckedContinuation { continuation in
                    Self.queue.async { continuation.resume(returning: evaluate()) }
                }
            }
            state.inFlight = running
            return .wait(running)
        }
        let task: Task<HostHealth, Never>
        switch decision {
        case .fresh(let health): return health
        case .wait(let running): task = running
        }
        let health = await task.value
        state.withLock { state in
            if state.inFlight == task {
                state.cached = (health, now())
                state.inFlight = nil
            }
        }
        return health
    }
}
