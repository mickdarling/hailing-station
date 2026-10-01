#if os(macOS)
import Darwin
import Foundation
import Synchronization

// Group ownership and launch remain one review boundary within the four production-path budget.
// swiftlint:disable file_length

struct OwnedReplyGroupHooks: Sendable {
    var beforeSpawn: @Sendable () -> Void = {}
    var beforeInstall: @Sendable () -> Void = {}
    var afterCancellationLatch: @Sendable () -> Void = {}
    var beforeResume: @Sendable () -> Void = {}
    var inventory: @Sendable (pid_t) -> [pid_t]? = OwnedReplyGroupJob.inventory
    var signal: @Sendable (Int32) -> Void = { _ in }
    var beforeReap: @Sendable () -> Void = {}
    var observation: @Sendable (Int32, Int32) -> Void = { _, _ in }
    var escalation: @Sendable () -> Void = {}
    var beforeCleanup: @Sendable (URL) -> Void = { _ in }
}

struct ReplyJobStartupRetention: Error {
    let directory: OwnedReplyJobDirectory
}

/// Each retained job emits its cleanup failure once; later observations are not new failures.
final class ReplyCleanupFailureReporter: Sendable {
    private let failure = Mutex<OwnedReplyPublisherError?>(nil)
    private let record: @Sendable (OwnedReplyPublisherError) -> Void
    init(record: @escaping @Sendable (OwnedReplyPublisherError) -> Void) { self.record = record }
    func report(_ value: OwnedReplyPublisherError) {
        failure.withLock { current in
            guard current == nil else { return }
            current = value
            record(value)
        }
    }
}

struct ReplyCleanupCallbacks: Sendable {
    let cleaned: @Sendable () -> Void
    let failed: @Sendable (OwnedReplyPublisherError) -> Void
}

/// No caller-supplied PID. The reservation is held by our unreaped child; terminal uncertainty
/// permanently retires signaling, and reaping happens only after the signal gate closes.
struct ReplyGroupIdentity: Sendable {
    let leader: pid_t
    var gateOpen = true
    var exited = false
    var lost = false
    var status: Int32?

    mutating func observe(result: Int32, information: siginfo_t, error: Int32) {
        guard gateOpen else { return }
        if result != 0, !(result == -1 && error == EINTR) { gateOpen = false; lost = true; return }
        if result == 0, information.si_pid != 0, information.si_pid != leader {
            gateOpen = false; lost = true; return
        }
        if result == 0, information.si_pid == leader,
           [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(information.si_code) {
            exited = true
            status = information.si_code == CLD_EXITED ? information.si_status : -1
        }
    }

    func permitsSignal(members: [pid_t]?) -> Bool {
        guard gateOpen, !lost, let members, members.count < 1_024,
              members.allSatisfy({ $0 > 0 }), Set(members).count == members.count else { return false }
        return members.contains(leader)
    }

    mutating func closeForReaping(members: [pid_t]?) -> Bool {
        guard gateOpen, !lost, exited, members == [leader] else { return false }
        gateOpen = false
        return true
    }
}

private struct ReplyGroupState {
    var identity: ReplyGroupIdentity
    var activated = false
    var resumed = false
    var failure: OwnedReplyPublisherError?
    var reported = false
    var escalationScheduled = false
    var killRequested = false
    var killSubmitted = false
    var pollScheduled = false
    var cleanupStarted = false
}

/// Fixed trusted, non-escaping CLI and renderer only. Not a sandbox or a kernel deadline guarantee.
/// The lifetime owner remains retained by its registry until cleanup actually succeeds.
final class OwnedReplyGroupJob: Sendable {
    private let folder: OwnedReplyJobDirectory
    private let state: Mutex<ReplyGroupState>
    private let source: any DispatchSourceProcess
    private let timer: any DispatchSourceTimer
    private let hooks: OwnedReplyGroupHooks
    private let outcome: @Sendable (Result<Void, OwnedReplyPublisherError>) -> Void
    private let cleaned: @Sendable () -> Void
    private let cleanupFailure: ReplyCleanupFailureReporter

    init(configuration: OwnedReplyPublisherConfiguration, reply: DiagnosticBridgeReply,
         cancelled: @Sendable () -> Bool,
         outcome: @escaping @Sendable (Result<Void, OwnedReplyPublisherError>) -> Void,
         cleanup: ReplyCleanupCallbacks) throws {
        try ReplyRendererChildIdentity.requireOwnedRuntime()
        guard !cancelled() else { throw OwnedReplyPublisherError.cancelled }
        configuration.hooks.beforeSpawn()
        guard !cancelled() else { throw OwnedReplyPublisherError.cancelled }
        folder = try OwnedReplyJobDirectory(root: configuration.root)
        guard folder.usable else { throw ReplyJobStartupRetention(directory: folder) }
        let pid: pid_t
        do {
            pid = try Self.spawn(configuration, reply: reply, root: folder.url)
        } catch {
            guard folder.remove() else { throw ReplyJobStartupRetention(directory: folder) }
            throw error
        }
        hooks = configuration.hooks
        self.outcome = outcome; self.cleaned = cleanup.cleaned
        cleanupFailure = ReplyCleanupFailureReporter(record: cleanup.failed)
        state = Mutex(ReplyGroupState(identity: ReplyGroupIdentity(leader: pid)))
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.setEventHandler { self.inspect() }
        timer.setEventHandler { self.cancel(.deadline) }
        timer.schedule(deadline: .now() + configuration.deadline.timeInterval)
        source.activate()
        timer.activate()
    }

    func activate(cancelled: Bool) {
        hooks.beforeResume()
        let earlyCancel = state.withLock { current -> Bool in
            guard !current.activated else { return current.failure != nil }
            current.activated = true
            return cancelled || current.failure != nil
        }
        if earlyCancel { cancel(.cancelled) } else {
            state.withLock { current in
                if current.failure == nil {
                    current.resumed = signal(SIGCONT, current: &current)
                }
            }
        }
        inspect()
    }

    func cancel(_ failure: OwnedReplyPublisherError) {
        let transition = state.withLock { current -> (Bool, Bool) in
            guard !current.cleanupStarted, current.failure == nil else { return (false, false) }
            current.failure = failure
            // A cancelled suspended job never executes fixture/client work before termination.
            if current.resumed { _ = signal(SIGTERM, current: &current) } else {
                current.killRequested = true
                current.killSubmitted = signal(SIGKILL, current: &current)
            }
            if !current.escalationScheduled { current.escalationScheduled = true; return (true, true) }
            return (true, false)
        }
        if transition.0 { report(.failure(failure)) }
        if transition.1 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                self.state.withLock { current in current.killRequested = true }
                self.hooks.escalation()
                self.inspect()
            }
        }
        inspect()
    }

    private func inspect() {
        let action = state.withLock { current -> Int in
            guard !current.cleanupStarted else { return 0 }
            observe(&current)
            if current.identity.lost { return 1 }
            if current.killRequested, !current.killSubmitted {
                current.killSubmitted = signal(SIGKILL, current: &current)
            } else if current.activated, !current.resumed, current.failure == nil {
                current.resumed = signal(SIGCONT, current: &current)
            }
            guard current.identity.exited else {
                return current.failure == nil && current.resumed ? 0 : 2
            }
            let members = hooks.inventory(current.identity.leader)
            guard current.identity.closeForReaping(members: members) else { return 2 }
            current.cleanupStarted = true
            return 3
        }
        switch action {
        case 1:
            cleanupFailure.report(.ownershipLost)
            report(.failure(.ownershipLost))
            source.setEventHandler {}; source.cancel()
            timer.setEventHandler {}; timer.cancel()
            // Registry retains directory/resource admission. Never reap/signal a raw lost identity.
        case 2: scheduleInspection()
        case 3: finishPinned()
        default: break
        }
    }

    private func scheduleInspection() {
        let schedule = state.withLock { current -> Bool in
            guard !current.pollScheduled, !current.cleanupStarted, !current.identity.lost else { return false }
            current.pollScheduled = true
            return true
        }
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) {
                self.state.withLock { $0.pollScheduled = false }
                self.inspect()
            }
        }
    }

    private func finishPinned() {
        hooks.beforeReap()
        let failure = state.withLock { current -> OwnedReplyPublisherError? in
            var status: Int32 = 0
            let reaped = waitpid(current.identity.leader, &status, WNOHANG)
            guard reaped == current.identity.leader else { return .ownershipLost }
            return current.failure ?? (current.identity.status == 0 ? nil : .commandFailed)
        }
        source.setEventHandler {}; source.cancel()
        timer.setEventHandler {}; timer.cancel()
        if failure == .ownershipLost {
            cleanupFailure.report(.ownershipLost)
            report(.failure(.ownershipLost)); return
        }
        // CLI acknowledgement and caller retirement are independent of potentially blocking IO.
        // Admission remains retained until successful removal; cleanup failure is a separate category.
        if let failure { report(.failure(failure)) } else { report(.success(())) }
        hooks.beforeCleanup(folder.url)
        guard folder.remove() else {
            cleanupFailure.report(.cleanupFailed)
            return
        }
        cleaned()
    }

    private func report(_ result: Result<Void, OwnedReplyPublisherError>) {
        let first = state.withLock { current -> Bool in
            guard !current.reported else { return false }
            current.reported = true; return true
        }
        if first { outcome(result) }
    }
}

extension OwnedReplyGroupJob {
    // All observation, signal admission and permanent cutoff share this lock. Exclusive waitable
    // ownership/default SIGCHLD throughout the job is a precondition, not coordinated external reaping.
    private func observe(_ current: inout ReplyGroupState) {
        guard current.identity.gateOpen else { return }
        var information = siginfo_t()
        // WNOHANG may leave siginfo untouched. Explicitly clear the sentinel before every call.
        information.si_pid = 0; information.si_code = 0
        let result = waitid(P_PID, id_t(current.identity.leader), &information, WEXITED | WNOHANG | WNOWAIT)
        let error = errno
        hooks.observation(result, error)
        current.identity.observe(result: result, information: information, error: error)
    }

    private func signal(_ value: Int32, current: inout ReplyGroupState) -> Bool {
        observe(&current)
        guard current.identity.gateOpen, !current.identity.lost,
              current.identity.permitsSignal(members: hooks.inventory(current.identity.leader)),
              kill(-current.identity.leader, value) == 0 else { return false }
        hooks.signal(value)
        return true
    }

    static func inventory(_ leader: pid_t) -> [pid_t]? {
        // proc_listpgrppids returns PID COUNT, unlike byte-count proc_listpids. Full capacity is
        // conservatively unknown, even if exactly full: no truncated inventory authorizes cleanup.
        var members = [pid_t](repeating: 0, count: 1_024)
        let count = members.withUnsafeMutableBytes {
            proc_listpgrppids(leader, $0.baseAddress, Int32($0.count))
        }
        guard count > 0, count < members.count else { return nil }
        let result = Array(members.prefix(Int(count)))
        guard result.allSatisfy({ $0 > 0 }), Set(result).count == result.count else { return nil }
        return result.sorted()
    }

    private static func spawn(_ configuration: OwnedReplyPublisherConfiguration,
                              reply: DiagnosticBridgeReply, root: URL) throws -> pid_t {
        let argv = [configuration.executable.path, "reply", DiagnosticReplyBridgeAdapter.targetID,
                    "--host", configuration.hostID, "--request", reply.requestID.uuidString,
                    "--say", reply.text, "--socket", configuration.socket.path,
                    "--renderer-output-root", root.path]
        let values = argv + configuration.environment.map { "\($0.key)=\($0.value)" }
        guard !values.contains(where: { $0.contains("\0") }) else {
            throw OwnedReplyPublisherError.invalidConfiguration
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw OwnedReplyPublisherError.startupFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw OwnedReplyPublisherError.startupFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        let setup = [posix_spawnattr_setpgroup(&attributes, 0),
                     posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED |
                                                                 POSIX_SPAWN_CLOEXEC_DEFAULT)),
                     posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
                     posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)]
        guard setup.allSatisfy({ $0 == 0 }) else { throw OwnedReplyPublisherError.startupFailed }
        var args = argv.map { strdup($0) } + [nil]
        var entries = configuration.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; entries.forEach { free($0) } }
        guard args.dropLast().allSatisfy({ $0 != nil }), entries.dropLast().allSatisfy({ $0 != nil }) else {
            throw OwnedReplyPublisherError.startupFailed
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, configuration.executable.path, &actions, &attributes, &args, &entries) == 0 else {
            throw OwnedReplyPublisherError.startupFailed
        }
        return pid
    }
}

private extension Duration {
    var timeInterval: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
#endif
