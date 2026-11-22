#if os(macOS)
import Darwin
public import Foundation
import Synchronization

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
        let manifest = coaching == nil ? BackgroundSelfVoice.ambientLaunch?.argumentsForSpawn() : nil
        let argv = Self.arguments(session: session, config: config, provenance: provenance,
                                  replyControl: hasControl) + (startPrivate ? [Self.startPrivateFlag] : []) + extra
            + (manifest ?? [])
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

    /// RightyO's start-private option (#735 S-2b; rightyo#242 round 2, provisional until that PR names it): the child
    /// is private before it reads any audio.
    static let startPrivateFlag = "--start-private"

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

/// Bound only around synchronous construction of an ambient pipeline. The child checks at argv assembly.
final class BackgroundSelfVoice: Sendable {
    @TaskLocal fileprivate static var ambientLaunch: BackgroundSelfVoice?

    static func launch(_ settings: RightyoAmbientPipeline.Configuration, dispatcher: any RightyoAmbientDispatching,
                       selfVoice: BackgroundSelfVoice?) throws -> RightyoAmbientPipeline {
        try $ambientLaunch.withValue(selfVoice) {
            try RightyoAmbientPipeline(configuration: settings, dispatcher: dispatcher)
        }
    }

    enum Reason: String { case pending, changed, mismatch }
    private struct State {
        var generation: SelfVoiceGeneration?
        var flight: Task<Void, Never>?
        var stopped = false
    }
    private let state = Mutex(State())
    private let preparation: SelfVoiceLaunchPreparation
    private let report: @Sendable (Reason) -> Void
    private let logQueue = DispatchQueue(label: "hailing.self-voice.log", qos: .utility)
    private let logSlots = DispatchSemaphore(value: 16)

    init(_ preparation: SelfVoiceLaunchPreparation, report: @escaping @Sendable (Reason) -> Void) {
        self.preparation = preparation
        self.report = report
        kick()
    }

    var inFlight: Task<Void, Never>? { state.withLock { $0.flight } }

    func kick() {
        state.withLock { state in
            guard !state.stopped, state.flight == nil else { return }
            state.flight = Task.detached(priority: .utility) { [weak self, preparation] in
                let result = await preparation.prepareGeneration()
                // Expiry revokes publication immediately. Coalesce kicks even during cancellation/reaping.
                await result.worker.value
                self?.state.withLock {
                    if !$0.stopped, let generation = result.generation { $0.generation = generation }
                    $0.flight = nil
                }
            }
        }
    }

    func stop() {
        let flight = state.withLock {
            $0.stopped = true
            $0.generation = nil
            return $0.flight
        }
        flight?.cancel()
    }

    deinit { inFlight?.cancel() }

    fileprivate func argumentsForSpawn() -> [String] {
        guard let generation = state.withLock({ $0.generation }) else { return fallback(.pending) }
        guard (try? SelfVoicePrivateFile.boundedBytes(preparation.enrollmentPath)) == generation.enrollmentBytes
        else { return fallback(.changed) }
        // Manifest v1 (ctx-1225-contracts.md:141): RightyO checks each WAV's SHA-256 against these
        // verified manifest bytes at startup and skips mismatches. No WAV I/O belongs on this path.
        guard let bytes = try? SelfVoicePrivateFile.boundedBytes(generation.manifest.path, privateDirectory: true),
              SelfVoiceWave.digest(bytes) == generation.manifestDigest else { return fallback(.mismatch) }
        return ["--self-voice-manifest", generation.manifest.path]
    }

    /// Child lifecycle events share this sink: a stalled started/ended write must not retain a live-run slot.
    func enqueueLog(_ write: @escaping @Sendable () -> Void) {
        if logSlots.wait(timeout: .now()) == .success {
            logQueue.async { [logSlots] in
                defer { logSlots.signal() }
                write()
            }
        }
    }

    private func fallback(_ reason: Reason) -> [String] {
        kick()
        enqueueLog { [report] in report(reason) }
        return []
    }
}

#endif
