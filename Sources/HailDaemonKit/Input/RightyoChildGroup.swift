#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// The RightyO child's own process group (#297). The child is spawned as the leader of a new group, so a wrapper
/// script's pipeline (`rightyo listen`, a tee, a player) shares it. The leader's exit ends ambient even while its
/// descendants still hold the stdio pipes: the rest of the group gets SIGTERM, SIGKILL after `termGrace`, and the
/// leader is reaped only once the group is empty or that last grace has passed too.
///
/// Signals go to the group by the leader's pid and only while the leader is unreaped: a live or zombie leader
/// reserves the pid, so no other process or group can hold that id. Exit is observed with `WNOWAIT`, which leaves
/// the zombie in place; observation, every signal and the final reap run on one serial queue, and once the leader
/// is reaped nothing is signalled again. A descendant that leaves the group (`setsid`/`setpgid`) is out of reach;
/// if it keeps stdout open, `abandonOutput` ends the line stream `transportLost` after `termGrace`.
final class RightyoChildGroup: Sendable {
    let leader: pid_t
    /// The leader's exit status, seen while it is still a zombie.
    let exit = RightyoExitLatch()
    /// The same status, set once the group has been ended and the leader reaped.
    let settled = RightyoExitLatch()
    private let termGrace: TimeInterval
    private let abandonOutput: @Sendable () -> Void
    private let queue = DispatchQueue(label: "hailing.rightyo-child.group")
    private let source: any DispatchSourceProcess
    private struct Cleanup { var started: UInt64?, killed = false, reaped = false }
    private let cleanup = Mutex(Cleanup())
    static let pollInterval: TimeInterval = 0.02

    /// Holds only its own state, never the child process object, so dropping the owner still runs its `deinit`.
    init(leader: pid_t, termGrace: TimeInterval, abandonOutput: @escaping @Sendable () -> Void) {
        (self.leader, self.termGrace, self.abandonOutput) = (leader, termGrace, abandonOutput)
        source = DispatchSource.makeProcessSource(identifier: leader, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in observe() }
        source.activate()
        // An exit before the source was armed raises no event.
        queue.async { [self] in observe() }
    }

    /// Signals the whole group while the leader is unreaped; afterwards there is nothing safe to signal.
    func signal(_ value: Int32) {
        queue.sync { if !cleanup.withLock({ $0.reaped }) { _ = kill(-leader, value) } }
    }

    /// Queue only. Reads the leader's status without reaping it, then starts ending the rest of the group.
    private func observe() {
        guard exit.value == nil else { return }
        var information = siginfo_t()
        information.si_pid = 0
        var result = waitid(P_PID, id_t(leader), &information, WEXITED | WNOHANG | WNOWAIT)
        while result == -1, errno == EINTR {
            result = waitid(P_PID, id_t(leader), &information, WEXITED | WNOHANG | WNOWAIT)
        }
        guard result == 0, information.si_pid == leader else { return }
        source.cancel()
        let status = information.si_code == CLD_EXITED ? RightyoChildExit.exited(information.si_status)
            : .signaled(information.si_status)
        exit.signal(status)
        cleanup.withLock { $0.started = DispatchTime.now().uptimeNanoseconds }
        if !Self.othersRemain(leader) { return reap(status) }
        _ = kill(-leader, SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.pollInterval) { [self] in poll(status) }
    }

    /// Queue only. SIGKILL once `termGrace` has passed since the leader exited; reap once the group is empty, or
    /// after a second `termGrace` regardless (a member stuck in the kernel must not hold ambient open forever).
    private func poll(_ status: RightyoChildExit) {
        let (elapsed, killed) = cleanup.withLock { state in
            (Double(DispatchTime.now().uptimeNanoseconds - (state.started ?? 0)) / 1e9, state.killed)
        }
        if !Self.othersRemain(leader) || (killed && elapsed >= 2 * termGrace) { return reap(status) }
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
        cleanup.withLock { $0.reaped = true }
        settled.signal(status)
        queue.asyncAfter(deadline: .now() + termGrace) { [abandonOutput] in abandonOutput() }
    }

    /// True while the group holds any process besides the leader, or when the inventory cannot be read.
    static func othersRemain(_ leader: pid_t) -> Bool {
        var members = [pid_t](repeating: 0, count: 1_024)
        // proc_listpgrppids returns a pid count. A zombie leader is still listed.
        let count = members.withUnsafeMutableBytes { proc_listpgrppids(leader, $0.baseAddress, Int32($0.count)) }
        guard count >= 0, count < members.count else { return true }
        return members.prefix(Int(count)).contains { $0 != leader }
    }
}
#endif
