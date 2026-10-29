// swiftlint:disable file_length
public import AVFAudio
public import Foundation
import Synchronization

/// Events a trigger emits as the user speaks. Push-to-talk, wake phrase, continuous, and intent-gate
/// triggers all produce this same stream (#5, #51).
public enum TriggerEvent: Sendable, Equatable {
    case utteranceStarted
    case utteranceFinal(String)
    case cancelled
}

/// How an utterance begins and ends. The rest of the pipeline never knows which trigger is active (#5).
public protocol Trigger: Sendable {
    var events: AsyncStream<TriggerEvent> { get }
}

/// An owned snapshot of one engine callback buffer, safe to hand to another concurrency domain.
public struct AudioCaptureBuffer: @unchecked Sendable {
    public let pcmBuffer: AVAudioPCMBuffer
    let admissionEpoch: UInt64

    public init?(copying buffer: AVAudioPCMBuffer) {
        self.init(copying: buffer, admissionEpoch: 0)
    }

    init?(copying buffer: AVAudioPCMBuffer, admissionEpoch: UInt64) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return nil }
        pcmBuffer = copy
        self.admissionEpoch = admissionEpoch
    }
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case alreadyRunning
}

/// Produces microphone buffers without deciding what they mean. Triggers and transcribers consume this seam (#5, #6).
public protocol AudioCapturing: Sendable {
    @MainActor func start() throws -> AsyncStream<AudioCaptureBuffer>
    @MainActor func stop()
}

/// AVAudioEngine-backed capture for the native terminal. The audio session remains owned by AudioSessionController.
/// The system can stop the engine underneath it (a call, Siri, a route or hardware change); capture then ends its
/// stream so every consumer sees the microphone stop, and posts `endedBySystem` so a consumer still draining
/// earlier audio can drop its "listening" state at once. It never restarts by itself (#218). Headphones attaching or
/// detaching as an output only, with the microphone unchanged, does not end a run whose engine still records (#343).
/// With a `StallPolicy`, a run whose engine stays "running" but delivers no buffers restarts the engine in place, on
/// the same stream; repeated stalls end the run as `endedBySystem` (#443).
@MainActor
public final class AVAudioEngineCapture: AudioCapturing {
    /// Posted on the capture's notification center, with the capture as object, after the system ended a run.
    public static let endedBySystem = Notification.Name("HailAudioCaptureEndedBySystem")
    /// `endedBySystem`'s `userInfo` key: `interruptionCause` when another app or a call took the microphone, so
    /// ambient listening can pause and resume instead of turning off (#445). Absent for every other end.
    public nonisolated static let endedCauseKey = "HailCaptureEndedCause"
    public nonisolated static let interruptionCause = "interruption"
    /// Posted, with the capture as object, each time a stalled engine is restarted (#443). Its `userInfo` holds
    /// `UInt` values under `stalledMillisecondsKey` and `restartAttemptKey`. A stall that ends the run posts
    /// `endedBySystem` instead.
    public static let stalled = Notification.Name("HailAudioCaptureStalled")
    public static let stalledMillisecondsKey = "HailCaptureStalledMilliseconds"
    public static let restartAttemptKey = "HailCaptureRestartAttempt"

    /// When a run counts as stalled (#443): no buffer for `limit`, on at least two consecutive checks every
    /// `check` (so one late wake after the app was suspended is not a stall). After `maxRestarts` restarts with no
    /// buffer in between, the next stall ends the run instead.
    public struct StallPolicy: Sendable, Equatable {
        public var limit: Duration
        public var check: Duration
        public var maxRestarts: Int

        public init(limit: Duration, check: Duration, maxRestarts: Int) {
            (self.limit, self.check, self.maxRestarts) = (limit, check, maxRestarts)
        }

        /// Ambient listening: a USB route once froze capture for 111 s with the engine still "running" (#443). Two
        /// restarts; the third stall in a row ends listening.
        public static let ambient = StallPolicy(limit: .seconds(5), check: .seconds(1), maxRestarts: 2)
    }

    private let engine: AVAudioEngine
    private let notificationCenter: NotificationCenter
    private let operations: AudioEngineOperations
    private let routeInputChanged: AudioCaptureEndingSignal.RouteInputChange
    private let routeOverrideWindow: AppRouteOverrideWindow
    private var continuation: AsyncStream<AudioCaptureBuffer>.Continuation?
    private var runID: UUID?
    private var admission: AudioCaptureAdmission?
    /// A system-ending run stays shut even if transport restoration reopens its shared admission.
    private var endingAdmission: AudioCaptureAdmission?
    private var hasTap = false
    private var starting = false
    private var observer: AudioCaptureEndingObserver?
    /// Read when a run starts; set it before `start` to watch that run for stalls (#443).
    var stallPolicy: StallPolicy?
    /// Called after a stalled engine restarted, so whatever plays through it can drop a reply the stall froze.
    var onEngineRestarted: (@MainActor () -> Void)?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Buffers delivered this run, counted on the audio thread; the watchdog only compares it with its last read.
    private let delivered = DeliveredBuffers()
    private var watchdog: Task<Void, Never>?
    private var routeEnd: Task<Void, Never>?
    private let routeInterruptionWindow: Duration

    public convenience init(
        engine: AVAudioEngine = AVAudioEngine(), notificationCenter: NotificationCenter = .default,
        stallPolicy: StallPolicy? = nil
    ) {
        self.init(engine: engine, notificationCenter: notificationCenter, operations: .live, stallPolicy: stallPolicy)
    }

    init(
        engine: AVAudioEngine, notificationCenter: NotificationCenter, operations: AudioEngineOperations,
        routeInputChanged: @escaping AudioCaptureEndingSignal.RouteInputChange = AudioCaptureEndingSignal.inputChanged,
        routeOverrideWindow: AppRouteOverrideWindow = .shared,
        stallPolicy: StallPolicy? = nil,
        routeInterruptionWindow: Duration = .milliseconds(200),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.notificationCenter = notificationCenter
        self.operations = operations
        self.routeInputChanged = routeInputChanged
        self.routeOverrideWindow = routeOverrideWindow
        self.stallPolicy = stallPolicy
        self.routeInterruptionWindow = routeInterruptionWindow
        self.now = now
        self.sleep = sleep
    }

    public func start() throws -> AsyncStream<AudioCaptureBuffer> {
        guard !operations.isRunning(engine), continuation == nil else { throw AudioCaptureError.alreadyRunning }
        starting = true
        defer { starting = false }

        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .unbounded)
        let streamContinuation = pair.continuation
        let id = UUID()
        runID = id
        continuation = streamContinuation
        streamContinuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.runID == id else { return }
                self.stop()
            }
        }

        admission = AudioCaptureAdmission.current ?? AudioCaptureAdmission()
        endingAdmission = AudioCaptureAdmission()
        installTap(streamContinuation)
        observeEndingSignals()
        do {
            try operations.start(engine)
        } catch {
            stop()
            throw error
        }
        if let stallPolicy { watchdog = watch(stallPolicy) }
        return pair.stream
    }

    private func observeEndingSignals() {
        // Observe before starting, so a call or route change that lands while the engine starts is not lost. Its
        // ending signal closes admission immediately; engine teardown is confined to the main actor.
        observer = AudioCaptureEndingObserver(
            center: notificationCenter, engine: engine, inputChanged: routeInputChanged,
            overrideWindow: routeOverrideWindow
        ) { [weak self, admission, endingAdmission] signal, id in
            // Unconditional endings close admission on the notification thread, before any actor hop.
            // Engine-dependent guards still use the running state after synchronous startup finishes.
            if signal.endsCapture(engineRunning: true) {
                endingAdmission?.setPaused(true)
                admission?.setPaused(true)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.systemSignalAfterStart(signal, observer: id) }
            } else {
                Task { @MainActor in self?.systemSignal(signal, observer: id) }
            }
        }
    }

    private func systemSignalAfterStart(_ signal: AudioCaptureEndingSignal, observer id: UUID) {
        guard !starting else {
            Task { @MainActor [weak self] in self?.systemSignal(signal, observer: id) }
            return
        }
        systemSignal(signal, observer: id)
    }

    public func stop() {
        runID = nil // Retire before finishing the stream can enqueue its termination callback.
        routeEnd?.cancel()
        routeEnd = nil
        watchdog?.cancel()
        watchdog = nil
        observer = nil
        if hasTap {
            operations.removeTap(engine)
            hasTap = false
        }
        operations.stop(engine)
        continuation?.finish()
        continuation = nil
    }

    /// Only the observer of the current run may end it; a late signal from an earlier run is ignored.
    private func systemSignal(_ signal: AudioCaptureEndingSignal, observer id: UUID) {
        guard observer?.id == id, signal.endsCapture(engineRunning: operations.isRunning(engine)) else { return }
        // A call can change the route before declaring its interruption. Keep the observer and stream alive
        // briefly so the interruption can supply the pause cause. Do not extend the window for more routes or
        // let the resulting engine reconfiguration preempt it. The existing running/self-override guards above
        // still decide whether a route needs an end at all.
        if case .routeChanged = signal {
            guard routeEnd == nil else { return }
            // Discard tap PCM and retire already queued epochs throughout the decision window.
            endingAdmission?.setPaused(true)
            admission?.setPaused(true)
            routeEnd = Task { @MainActor [weak self, sleep, routeInterruptionWindow] in
                guard (try? await sleep(routeInterruptionWindow)) != nil, !Task.isCancelled,
                      let self, self.observer?.id == id else { return }
                self.endBySystem(reason: signal.endReason)
            }
            return
        }
        if signal == .engineConfigurationChanged, routeEnd != nil { return }
        endBySystem(reason: signal.endReason, interrupted: signal == .interruptionBegan)
    }

    /// `endedBySystem`'s `userInfo` key: the `ambient_stop` reason token for what ended the run (#459).
    public nonisolated static let endedReasonKey = "HailCaptureEndedReason"

    /// Posts the reason token (#459) and, for an interruption, the pause marker (#445).
    private func endBySystem(reason: String = "capture_ended", interrupted: Bool = false) {
        stop()
        var info: [String: String] = [Self.endedReasonKey: reason]
        if interrupted { info[Self.endedCauseKey] = Self.interruptionCause }
        notificationCenter.post(name: Self.endedBySystem, object: self, userInfo: info)
    }

    private func installTap(_ continuation: AsyncStream<AudioCaptureBuffer>.Continuation) {
        let delivered = delivered
        let admission = admission
        let endingAdmission = endingAdmission
        operations.installTap(engine) { @Sendable buffer, _ in
            delivered.increment()
            guard endingAdmission?.isPaused != true,
                  let ownedBuffer = AudioCaptureAdmission.copy(buffer, through: admission) else { return }
            continuation.yield(ownedBuffer)
        }
        hasTap = true
    }
}

/// The stall watchdog (#443). It runs on the main actor for one run; `stop` cancels it.
extension AVAudioEngineCapture {
    private func watch(_ policy: StallPolicy) -> Task<Void, Never> {
        let (now, sleep, delivered) = (now, sleep, delivered)
        return Task { @MainActor [weak self] in
            var seen = delivered.count
            var since = now()
            var restarts = 0
            var staleChecks = 0
            while true {
                guard (try? await sleep(policy.check)) != nil, !Task.isCancelled, let self,
                      self.continuation != nil else { return }
                let current = delivered.count
                if current != seen {
                    (seen, since, restarts, staleChecks) = (current, now(), 0, 0)
                    continue
                }
                staleChecks += 1
                let stalled = now() - since
                // A single check that wakes long after the last (the app was suspended) is not yet a stall.
                guard stalled >= policy.limit, staleChecks >= 2 else { continue }
                restarts += 1
                guard self.restartStalled(after: stalled, attempt: restarts, policy: policy) else { return }
                (since, staleChecks) = (now(), 0)
            }
        }
    }

    /// Restarts the engine on the same stream and reports it. Past `maxRestarts`, or if the engine won't start
    /// again, the run ends as if the system had stopped it, with no "restarted" report. Returns whether it goes on.
    private func restartStalled(after stalled: Duration, attempt: Int, policy: StallPolicy) -> Bool {
        guard attempt <= policy.maxRestarts, let continuation else {
            endBySystem()
            return false
        }
        if hasTap {
            operations.removeTap(engine)
            hasTap = false
        }
        operations.stop(engine)
        installTap(continuation)
        do {
            try operations.start(engine)
        } catch {
            endBySystem()
            return false
        }
        let (seconds, attoseconds) = stalled.components
        let milliseconds = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
        notificationCenter.post(name: Self.stalled, object: self, userInfo: [
            Self.stalledMillisecondsKey: UInt(clamping: milliseconds), Self.restartAttemptKey: UInt(clamping: attempt)
        ])
        onEngineRestarted?()
        return true
    }
}

/// A count of tap callbacks, bumped on the audio thread and read on the main actor.
final class DeliveredBuffers: Sendable {
    private let value = Atomic<UInt64>(0)
    func increment() { value.wrappingAdd(1, ordering: .relaxed) }
    var count: UInt64 { value.load(ordering: .relaxed) }
}

/// The engine calls capture makes. Tests substitute them to simulate the system around a run without a microphone.
struct AudioEngineOperations {
    typealias Tap = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    var installTap: @MainActor (AVAudioEngine, @escaping Tap) -> Void
    var removeTap: @MainActor (AVAudioEngine) -> Void
    var start: @MainActor (AVAudioEngine) throws -> Void
    var stop: @MainActor (AVAudioEngine) -> Void
    var isRunning: @MainActor (AVAudioEngine) -> Bool

    @MainActor static let live = AudioEngineOperations(
        installTap: { engine, tap in
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 4_096, format: input.outputFormat(forBus: 0), block: tap)
        },
        removeTap: { $0.inputNode.removeTap(onBus: 0) },
        start: { engine in
            engine.prepare()
            try engine.start()
        },
        stop: { $0.stop() },
        isRunning: { $0.isRunning }
    )
}

/// A system event that may have stopped capture underneath the engine (#218).
enum AudioCaptureEndingSignal: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded
    /// `inputChanged` is false only when the route change left the input ports as they were (#343). `selfOverride`
    /// marks an `override` the app itself made while restoring the preferred input (#459).
    case routeChanged(reason: UInt, inputChanged: Bool = true, selfOverride: Bool = false)
    case mediaServicesReset
    case engineConfigurationChanged

    /// Route-change reasons that move the input or output hardware: `newDeviceAvailable`,
    /// `oldDeviceUnavailable`, `override`, `wakeFromSleep`, `noSuitableRouteForCategory`.
    static let hardwareRouteReasons: Set<UInt> = [1, 2, 4, 6, 7]

    /// An interruption ends capture; there is no auto-resume. A hardware route change ends it when it changed the
    /// input, or when no route suits the category. An output-only change, such as AirPods attaching over A2DP while
    /// the built-in mic keeps recording, does not (#343). Other route changes (such as the category change capture's
    /// own session activation causes) and engine reconfiguration end it only when the engine has actually stopped,
    /// so the stream never claims to be live while nothing records.
    func endsCapture(engineRunning: Bool) -> Bool {
        switch self {
        case .interruptionBegan, .mediaServicesReset: true
        case .interruptionEnded: false
        case .routeChanged(_, _, true): !engineRunning
        case .routeChanged(let reason, let inputChanged, false):
            (Self.hardwareRouteReasons.contains(reason) && (inputChanged || reason == Self.noSuitableRoute))
                || !engineRunning
        case .engineConfigurationChanged: !engineRunning
        }
    }

    static let noSuitableRoute: UInt = 7
    static let override: UInt = 4

    /// The `ambient_stop` reason token for a run this signal ended (#459): the route-change reason, or
    /// `system_interruption` for a call or Siri, or `capture_ended` when the engine or media services stopped.
    var endReason: String {
        switch self {
        case .interruptionBegan, .interruptionEnded: "system_interruption"
        case .routeChanged(let reason, _, _): DeviceDiagnostics.routeChangeReason(reason)
        case .mediaServicesReset, .engineConfigurationChanged: "capture_ended"
        }
    }

    /// Whether a route-change notification changed the input ports.
    typealias RouteInputChange = @Sendable (Notification) -> Bool

    /// Compares the previous route's inputs with the current ones. Without a previous route (and off iOS) it
    /// answers true, so capture ends as it did before #343.
    static let inputChanged: RouteInputChange = { notification in
        #if os(iOS)
        guard let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription else { return true }
        let current = AVAudioSession.sharedInstance().currentRoute.inputs
        return inputsDiffer(previous: previous.inputs.map(\.uid), current: current.map(\.uid))
        #else
        return true
        #endif
    }

    static func inputsDiffer(previous: [String], current: [String]) -> Bool { Set(previous) != Set(current) }

    /// Notification names and keys. They are the `AVAudioSession` constants on iOS; macOS has no session, so the
    /// same names are spelled out for the host-side tests.
    enum Names {
        #if os(iOS)
        static let interruption = AVAudioSession.interruptionNotification
        static let routeChange = AVAudioSession.routeChangeNotification
        static let mediaServicesReset = AVAudioSession.mediaServicesWereResetNotification
        static let interruptionTypeKey = AVAudioSessionInterruptionTypeKey
        static let routeChangeReasonKey = AVAudioSessionRouteChangeReasonKey
        #else
        static let interruption = Notification.Name("AVAudioSessionInterruptionNotification")
        static let routeChange = Notification.Name("AVAudioSessionRouteChangeNotification")
        static let mediaServicesReset = Notification.Name("AVAudioSessionMediaServicesWereResetNotification")
        static let interruptionTypeKey = "AVAudioSessionInterruptionTypeKey"
        static let routeChangeReasonKey = "AVAudioSessionRouteChangeReasonKey"
        #endif
    }

    /// `AVAudioSession.InterruptionType.began` is 1 and `.ended` is 0; a missing type is treated as began.
    init?(
        _ notification: Notification, inputChanged: RouteInputChange = Self.inputChanged,
        overrideWindow: AppRouteOverrideWindow = .shared
    ) {
        switch notification.name {
        case Names.interruption:
            let type = notification.userInfo?[Names.interruptionTypeKey] as? UInt
            self = type == 0 ? .interruptionEnded : .interruptionBegan
        case Names.routeChange:
            let reason = notification.userInfo?[Names.routeChangeReasonKey] as? UInt ?? 0
            self = .routeChanged(
                reason: reason, inputChanged: inputChanged(notification),
                selfOverride: reason == Self.override && overrideWindow.isOpen
            )
        case Names.mediaServicesReset: self = .mediaServicesReset
        case .AVAudioEngineConfigurationChange: self = .engineConfigurationChanged
        default: return nil
        }
    }
}

/// Watches the session notifications and one engine's configuration changes for the life of one capture run.
/// Handlers run on the posting thread, so only a parsed, sendable signal leaves them.
final class AudioCaptureEndingObserver {
    typealias Handler = @Sendable (AudioCaptureEndingSignal, UUID) -> Void
    let id = UUID()
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(
        center: NotificationCenter, engine: AnyObject?,
        inputChanged: @escaping AudioCaptureEndingSignal.RouteInputChange = AudioCaptureEndingSignal.inputChanged,
        overrideWindow: AppRouteOverrideWindow = .shared,
        handler: @escaping Handler
    ) {
        self.center = center
        let id = id
        let names = [Names.interruption, Names.routeChange, Names.mediaServicesReset]
        let sessionNames = names.map { ($0, nil as AnyObject?) }
        for (name, object) in sessionNames + [(.AVAudioEngineConfigurationChange, engine)] {
            tokens.append(center.addObserver(forName: name, object: object, queue: nil) { notification in
                guard let signal = AudioCaptureEndingSignal(
                    notification, inputChanged: inputChanged, overrideWindow: overrideWindow
                ) else { return }
                handler(signal, id)
            })
        }
    }

    private typealias Names = AudioCaptureEndingSignal.Names

    deinit { tokens.forEach(center.removeObserver) }
}

/// #904: scoped through synchronous capture wrappers at start; the tap retains it across engine heals. Closing it
/// discards before copying or yielding. Epochs also retire buffers/encoders/queues already ahead of the drop.
final class AudioCaptureAdmission: Sendable {
    @TaskLocal static var current: AudioCaptureAdmission?
    private struct State { var epoch: UInt64 = 0; var paused = false }
    private let state = Mutex(State())
    var epoch: UInt64 { state.withLock { $0.epoch } }
    var isPaused: Bool { state.withLock { $0.paused } }
    func accepts(_ epoch: UInt64) -> Bool { state.withLock { !$0.paused && $0.epoch == epoch } }
    func setPaused(_ paused: Bool) {
        state.withLock { $0.epoch &+= 1; $0.paused = paused }
    }
    func copy(_ buffer: AVAudioPCMBuffer) -> AudioCaptureBuffer? {
        state.withLock { state in
            guard !state.paused else { return nil }
            return AudioCaptureBuffer(copying: buffer, admissionEpoch: state.epoch)
        }
    }
    static func copy(_ buffer: AVAudioPCMBuffer, through admission: AudioCaptureAdmission?) -> AudioCaptureBuffer? {
        if let admission { return admission.copy(buffer) }
        return AudioCaptureBuffer(copying: buffer)
    }
}
