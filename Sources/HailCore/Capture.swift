// swiftlint:disable file_length
public import AVFAudio
public import Foundation

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

    public init?(copying buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return nil }
        pcmBuffer = copy
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
@MainActor
public final class AVAudioEngineCapture: AudioCapturing {
    /// Posted on the capture's notification center, with the capture as object, after the system ended a run.
    public static let endedBySystem = Notification.Name("HailAudioCaptureEndedBySystem")

    private let engine: AVAudioEngine
    private let notificationCenter: NotificationCenter
    private let operations: AudioEngineOperations
    private let routeInputChanged: AudioCaptureEndingSignal.RouteInputChange
    private var continuation: AsyncStream<AudioCaptureBuffer>.Continuation?
    private var hasTap = false
    private var observer: AudioCaptureEndingObserver?

    public convenience init(
        engine: AVAudioEngine = AVAudioEngine(), notificationCenter: NotificationCenter = .default
    ) {
        self.init(engine: engine, notificationCenter: notificationCenter, operations: .live)
    }

    init(
        engine: AVAudioEngine, notificationCenter: NotificationCenter, operations: AudioEngineOperations,
        routeInputChanged: @escaping AudioCaptureEndingSignal.RouteInputChange = AudioCaptureEndingSignal.inputChanged
    ) {
        self.engine = engine
        self.notificationCenter = notificationCenter
        self.operations = operations
        self.routeInputChanged = routeInputChanged
    }

    public func start() throws -> AsyncStream<AudioCaptureBuffer> {
        guard !operations.isRunning(engine), continuation == nil else { throw AudioCaptureError.alreadyRunning }

        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .unbounded)
        let streamContinuation = pair.continuation
        continuation = streamContinuation
        streamContinuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.stop() }
        }

        operations.installTap(engine) { @Sendable buffer, _ in
            guard let ownedBuffer = AudioCaptureBuffer(copying: buffer) else { return }
            streamContinuation.yield(ownedBuffer)
        }
        hasTap = true
        // Observe before starting, so a call or route change that lands while the engine starts is not lost. Its
        // signal is handled on the main actor after `start` returns, against the engine's state at that point.
        observer = AudioCaptureEndingObserver(
            center: notificationCenter, engine: engine, inputChanged: routeInputChanged
        ) { [weak self] signal, id in
            Task { @MainActor in self?.systemSignal(signal, observer: id) }
        }
        do {
            try operations.start(engine)
        } catch {
            stop()
            throw error
        }
        return pair.stream
    }

    public func stop() {
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
        stop()
        notificationCenter.post(name: Self.endedBySystem, object: self)
    }
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
    /// `inputChanged` is false only when the route change left the input ports as they were (#343).
    case routeChanged(reason: UInt, inputChanged: Bool = true)
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
        case .routeChanged(let reason, let inputChanged):
            (Self.hardwareRouteReasons.contains(reason) && (inputChanged || reason == Self.noSuitableRoute))
                || !engineRunning
        case .engineConfigurationChanged: !engineRunning
        }
    }

    static let noSuitableRoute: UInt = 7

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
    init?(_ notification: Notification, inputChanged: RouteInputChange = Self.inputChanged) {
        switch notification.name {
        case Names.interruption:
            let type = notification.userInfo?[Names.interruptionTypeKey] as? UInt
            self = type == 0 ? .interruptionEnded : .interruptionBegan
        case Names.routeChange:
            self = .routeChanged(
                reason: notification.userInfo?[Names.routeChangeReasonKey] as? UInt ?? 0,
                inputChanged: inputChanged(notification)
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
        handler: @escaping Handler
    ) {
        self.center = center
        let id = id
        let names = [Names.interruption, Names.routeChange, Names.mediaServicesReset]
        let sessionNames = names.map { ($0, nil as AnyObject?) }
        for (name, object) in sessionNames + [(.AVAudioEngineConfigurationChange, engine)] {
            tokens.append(center.addObserver(forName: name, object: object, queue: nil) { notification in
                guard let signal = AudioCaptureEndingSignal(notification, inputChanged: inputChanged) else { return }
                handler(signal, id)
            })
        }
    }

    private typealias Names = AudioCaptureEndingSignal.Names

    deinit { tokens.forEach(center.removeObserver) }
}
