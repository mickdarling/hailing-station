#if os(macOS)
import Darwin
public import Foundation

/// Rightyo stdin child (#203): raw mono16k s16le in, JSONL out; fixed argv, no shell, minimal environment.
/// Working directory = config parent. Audio/stdout never logged; stderr discarded with byte count only.
public final class RightyoChildProcess: Sendable {
    public static let maxLineBytes = 1_200_000
    /// Untaken stdout lines are byte bounded, not count bounded; excess ends with `backlog`.
    public static let maxQueuedBytes = 4_000_000
    /// stdout split on newlines (empty lines skipped). Ends at EOF, or throws a `RightyoChildError`.
    public let lines: RightyoChildOutput
    public let processIdentifier: Int32
    let input: RightyoStdinWriter
    let control: RightyoControlWriter
    let coachingControl: RightyoCoachingControlWriter?
    private let outputRevocation: RightyoOutputRevocation?
    /// Owned group (#297): one queue observes exit/signals/reaps, preventing PID reuse.
    private let group: RightyoChildGroup
    private let stderrBytes = RightyoByteCount()
    private let timing: Timing
    /// Fixed validated executable/argv/environment; only RIGHTYO_ additions (#172). Coaching is explicitly opt-in.
    /// `startPrivate` (#735 S-2b) adds RightyO's start-private option; never with coaching.
    public init(executable: URL, config: URL, session: String, provenance: RightyoAudioProvenance = .liveMicrophone,
                timing: Timing = .init(), replyControl: Bool = false, env: [String: String] = [:],
                coaching: RightyoCoachingLaunch? = nil, startPrivate: Bool = false) throws {
        guard coaching == nil || (!replyControl && !startPrivate) else { throw RightyoChildError.unsafeConfig }
        let extra = try coaching?.arguments(session: session, provenance: provenance) ?? []
        let hasControl = replyControl || coaching != nil
        let resolved = try Self.validate(executable: executable, config: config)
        try RightyoChildGroup.requireOwnedRuntime()
        let argv = Self.arguments(session: session, config: config, provenance: provenance,
                                  replyControl: hasControl, startPrivate: startPrivate) + extra
        let environment = Self.environment().merging(env.filter { $0.key.hasPrefix("RIGHTYO_") }) { old, _ in old }
        let child = try Self.spawn(resolved, arguments: argv, environment: environment.map { "\($0.key)=\($0.value)" },
                                   directory: config.deletingLastPathComponent().path, replyControl: hasControl)
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
        let queued = RightyoByteCount()
        let revocation = coaching == nil ? nil : RightyoOutputRevocation()
        outputRevocation = revocation
        // The leader's exit ends the stream even if a descendant that left the group still holds stdout (#297).
        let continuation = pair.continuation, ended = RightyoByteCount()
        continuation.onTermination = { _ in ended.withLock { $0 = 1 } }
        group = RightyoChildGroup(leader: child.pid, termGrace: timing.termGrace) {
            revocation?.ownedGroupEnded()
            guard ended.withLock({ $0 }) == 0 else { return false }
            continuation.finish(throwing: RightyoChildError.transportLost)
            return true
        }
        input = RightyoStdinWriter(input: child.input, exit: group.exit, timing: timing) {
            guard let revocation else { return }
            revocation.revoke(); continuation.finish(throwing: RightyoChildError.transportLost)
        }
        control = RightyoControlWriter(coaching == nil ? child.control : nil)
        coachingControl = coaching == nil ? nil
            : Self.coachingWriter(child.control, input: input, continuation: continuation, revocation: revocation)
        lines = RightyoChildOutput(base: RightyoChildLines(stream: pair.stream, queued: queued),
                                   revocation: revocation, control: coachingControl,
                                   exit: coaching == nil ? nil : group.exit)
        Self.observeCoachingExit(group.exit, revocation: revocation, continuation: continuation)
        (processIdentifier, self.timing) = (child.pid, timing)
        Thread.detachNewThread { RightyoChildLines.read(child.output, into: pair.continuation, queued: queued) }
        Thread.detachNewThread { [stderrBytes] in
            Self.drainErrors(child.errors) { count in stderrBytes.withLock { $0 += count } }
        }
    }

    /// Drop abandons stdin and kills only the owned group, which still reaps.
    deinit {
        outputRevocation?.revoke()
        input.close(abandon: true)
        coachingControl?.close()
        group.signal(SIGKILL)
    }

    public var counters: Counters {
        var counters = input.counters
        counters.stderrBytes = stderrBytes.withLock { $0 }
        return counters
    }
    public var exitStatus: RightyoChildExit? { group.exit.value }
    /// EOF, owned SIGTERM/SIGKILL and reap. Bounded by `eofGrace + 3 * termGrace + 1` (10s by default).
    /// If not settled, returns the observed exit or SIGKILL; the owned supervisor continues cleanup (#366).
    @discardableResult public func stop(eofGrace: TimeInterval? = nil, termGrace: TimeInterval? = nil) async
        -> RightyoChildExit {
        let (eofGrace, termGrace) = (eofGrace ?? timing.eofGrace, termGrace ?? timing.termGrace); closeInput()
        if await group.exit.wait(timeout: eofGrace) == nil {
            group.signal(SIGTERM)
            if await group.exit.wait(timeout: termGrace) == nil { group.signal(SIGKILL) }
        }
        let settled = await group.settled.wait(timeout: 2 * termGrace + 1)
        return settled ?? group.exit.value ?? .signaled(SIGKILL)
    }
}

#endif
