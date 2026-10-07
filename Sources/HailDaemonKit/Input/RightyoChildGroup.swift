#if os(macOS)
import Darwin
import Foundation
import os
import Synchronization

private let groupLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "ambient-child")

/// The RightyO child's own process group (#297). The child is spawned as the leader of a new group, so a wrapper
/// script's pipeline (`rightyo listen`, a tee, a player) shares it. The leader's exit ends ambient even while its
/// descendants still hold the stdio pipes: the rest of the group gets SIGTERM, SIGKILL after `termGrace`, and the
/// leader is reaped only once the group is empty or a second `termGrace` has passed too.
///
/// Signals go to the group by the leader's pid, and to the leader itself in case it moved to another group, only
/// while the leader is unreaped: a live or zombie leader reserves the pid, so no other process or group can hold
/// that id. Exit is observed with `WNOWAIT`, which leaves the zombie in place; observation, every signal and the
/// final reap run on one serial queue, and once the leader is reaped (or found already gone) nothing is signalled
/// again. A descendant that leaves the group (`setsid`/`setpgid`) is out of reach; if it keeps stdout open,
/// `abandonOutput` ends the line stream `transportLost` after `termGrace`. Logs carry pids and counts only.
final class RightyoChildGroup: Sendable {
    let leader: pid_t
    /// The leader's exit status, seen while it is still a zombie.
    let exit = RightyoExitLatch()
    /// The same status, set once the group has been ended and the leader reaped.
    let settled = RightyoExitLatch()
    private let termGrace: TimeInterval
    private let abandonOutput: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "hailing.rightyo-child.group")
    private let source: any DispatchSourceProcess
    private struct Cleanup { var started: UInt64?, notified = false, termed = 0, killed = false, reaped = false }
    private let cleanup = Mutex(Cleanup())
    static let pollInterval: TimeInterval = 0.02

    /// Holds only its own state, never the child process object, so dropping the owner still runs its `deinit`.
    /// `abandonOutput` ends the line stream and returns false when it had already ended.
    init(leader: pid_t, termGrace: TimeInterval, abandonOutput: @escaping @Sendable () -> Bool) {
        precondition(leader > 1, "RightyoChildGroup needs a spawned child's pid")
        (self.leader, self.termGrace, self.abandonOutput) = (leader, termGrace, abandonOutput)
        source = DispatchSource.makeProcessSource(identifier: leader, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in observe(notified: true) }
        source.activate()
        // An exit before the source was armed raises no event.
        queue.async { [self] in observe(notified: false) }
    }

    /// Exit observation and reaping need SIGCHLD at its default, without `SA_NOCLDWAIT`, as for owned replies.
    static func requireOwnedRuntime() throws {
        var action = sigaction()
        guard sigaction(SIGCHLD, nil, &action) == 0,
              ReplyRendererChildIdentity.supportsOwnership(
                handler: unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self), flags: action.sa_flags)
        else { throw RightyoChildError.transportLost }
    }

    /// Signals the group and the leader while the leader is unreaped; afterwards there is nothing safe to signal.
    func signal(_ value: Int32) {
        queue.sync {
            guard !cleanup.withLock({ $0.reaped }) else { return }
            _ = kill(-leader, value)
            _ = kill(leader, value)
        }
    }

    /// Queue only. Reads the leader's status without reaping it, then starts ending the rest of the group. The exit
    /// event is not proof that status is waitable yet, so once notified this re-polls until it is conclusive.
    private func observe(notified: Bool) {
        guard exit.value == nil, !cleanup.withLock({ $0.reaped }) else { return }
        if notified { cleanup.withLock { $0.notified = true } }
        var information = siginfo_t()
        information.si_pid = 0
        information.si_code = 0
        let result = waitid(P_PID, id_t(leader), &information, WEXITED | WNOHANG | WNOWAIT)
        let error = errno
        if result == -1, error == ECHILD { return lost() }
        guard result == 0, information.si_pid == leader else {
            if cleanup.withLock({ $0.notified }) {
                queue.asyncAfter(deadline: .now() + Self.pollInterval) { [self] in observe(notified: false) }
            }
            return
        }
        source.cancel()
        let status = information.si_code == CLD_EXITED ? RightyoChildExit.exited(information.si_status)
            : .signaled(information.si_status)
        exit.signal(status)
        let others = Self.others(leader)
        cleanup.withLock { $0.started = DispatchTime.now().uptimeNanoseconds; $0.termed = others ?? -1 }
        if others == 0 { return reap(status) }
        _ = kill(-leader, SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.pollInterval) { [self] in poll(status) }
    }

    /// Queue only. SIGKILL once `termGrace` has passed since the leader exited; reap once the group is empty, or
    /// after a second `termGrace` regardless (a member stuck in the kernel must not hold ambient open forever).
    private func poll(_ status: RightyoChildExit) {
        let (elapsed, killed) = cleanup.withLock { state in
            (Double(DispatchTime.now().uptimeNanoseconds - (state.started ?? 0)) / 1e9, state.killed)
        }
        if Self.others(leader) == 0 || (killed && elapsed >= 2 * termGrace) { return reap(status) }
        if elapsed >= termGrace, !killed {
            cleanup.withLock { $0.killed = true }
            _ = kill(-leader, SIGKILL)
        }
        queue.asyncAfter(deadline: .now() + Self.pollInterval) { [self] in poll(status) }
    }

    /// Queue only, and only after `WNOWAIT` saw the exit, so the exact-pid reap cannot block.
    private func reap(_ status: RightyoChildExit) {
        var raw: Int32 = 0
        while waitpid(leader, &raw, 0) == -1, errno == EINTR {}
        let (termed, killed) = cleanup.withLock { state in
            state.reaped = true
            return (state.termed, state.killed)
        }
        if termed != 0 {
            groupLogger.notice("""
                Ambient child group ended after its leader: leader=\(self.leader, privacy: .public) \
                termed=\(termed, privacy: .public) killed=\(killed, privacy: .public)
                """)
        }
        settled.signal(status)
        scheduleAbandon()
    }

    /// Queue only. The leader was reaped elsewhere (or never waitable): nothing more may be signalled.
    private func lost() {
        cleanup.withLock { $0.reaped = true }
        source.cancel()
        groupLogger.error("Ambient child leader lost before its exit was seen: leader=\(self.leader, privacy: .public)")
        exit.signal(.signaled(SIGKILL))
        settled.signal(.signaled(SIGKILL))
        scheduleAbandon()
    }

    private func scheduleAbandon() {
        queue.asyncAfter(deadline: .now() + termGrace) { [leader, abandonOutput] in
            guard abandonOutput() else { return }
            groupLogger.notice("""
                Ambient child output abandoned: a process outside the group held it, leader=\(leader, privacy: .public)
                """)
        }
    }

    /// Group members besides the leader; nil when unknown. While the leader is unreaped it is always listed (a
    /// zombie too), so an empty or failed inventory (`proc_listpgrppids` returns 0 for both) is unknown, not empty.
    static func others(_ leader: pid_t) -> Int? {
        var members = [pid_t](repeating: 0, count: 1_024)
        // proc_listpgrppids returns a pid count, not bytes.
        let count = members.withUnsafeMutableBytes { proc_listpgrppids(leader, $0.baseAddress, Int32($0.count)) }
        guard count > 0, count < members.count else { return nil }
        let listed = members.prefix(Int(count))
        guard listed.contains(leader) else { return nil }
        return listed.filter { $0 != leader }.count
    }
}
#endif
