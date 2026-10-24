#if os(iOS)
import AVFoundation
import Foundation

@MainActor
public final class AVAudioSessionBackend: AudioSessionBackend {
    private let session: AVAudioSession
    private let events: AsyncStream<AudioSessionBackendEvent>
    private let continuation: AsyncStream<AudioSessionBackendEvent>.Continuation
    private let observers = NotificationObserverBag()
    private var outputRouteState = AudioOutputRoutePolicy.State()
    private var isRepairingOutputRoute = false

    public convenience init() {
        self.init(session: .sharedInstance())
    }

    init(session: AVAudioSession) {
        self.session = session
        let pair = AsyncStream<AudioSessionBackendEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = pair.stream
        continuation = pair.continuation
        observeNotifications()
    }

    deinit {
        continuation.finish()
    }

    public func configure(allowsBluetoothHFP: Bool) async throws {
        try AudioOutputSessionRouting.configure(session, allowsBluetoothHFP: allowsBluetoothHFP)
    }

    public func setActive(_ active: Bool) async throws {
        if active {
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    public func availableInputs() async -> [AudioPort] {
        (session.availableInputs ?? []).map(Self.port)
    }

    public func selectInput(id: AudioPort.ID?) async throws {
        let selected = session.availableInputs?.first { $0.uid == id }
        try session.setPreferredInput(selected)
    }

    public func diagnostics(isActive: Bool) async -> AudioSessionDiagnostics {
        let route = session.currentRoute
        return AudioSessionDiagnostics(
            isActive: isActive,
            input: route.inputs.first.map(Self.port),
            outputs: route.outputs.map(Self.port),
            sampleRate: session.sampleRate
        )
    }

    public func eventStream() async -> AsyncStream<AudioSessionBackendEvent> {
        events
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observers.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self, continuation] notification in
            let snapshot = AudioOutputSessionRouting.snapshot(notification)
            MainActor.assumeIsolated { self?.repairOutputRoute(snapshot) }
            continuation.yield(.routeChanged)
        })
        observers.add(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [continuation] notification in
            continuation.yield(Self.interruptionEvent(notification))
        })
    }

    private func repairOutputRoute(_ snapshot: AudioOutputSessionRouting.Snapshot) {
        guard !isRepairingOutputRoute else { return }
        let route = AudioOutputSessionRouting.route(session, snapshot: snapshot)
        isRepairingOutputRoute = true
        defer { isRepairingOutputRoute = false }
        let session = session
        AudioOutputRouteDriver.process(route, state: &outputRouteState, observeDecision: { decision in
            #if DEBUG
            if decision.preservedRouteChoice {
                print("Output route left unchanged: user choice or ambiguous cause (#852)")
            }
            #endif
        }, perform: { effect in
            try AudioOutputSessionRouting.apply(effect, to: session)
        })
    }

    nonisolated private static func interruptionEvent(_ notification: Notification) -> AudioSessionBackendEvent {
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard rawType == AVAudioSession.InterruptionType.ended.rawValue else {
            return .interruptionBegan
        }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        return .interruptionEnded(shouldResume: options.contains(.shouldResume))
    }

    private static func port(_ description: AVAudioSessionPortDescription) -> AudioPort {
        AudioPort(
            id: description.uid,
            name: description.portName,
            kind: kind(description.portType)
        )
    }

    private static func kind(_ type: AVAudioSession.Port) -> AudioInputKind {
        switch type {
        case .usbAudio: .usb
        case .headsetMic, .lineIn: .wired
        case .bluetoothHFP: .bluetoothHFP
        case .builtInMic: .builtIn
        default: .other
        }
    }
}

private final class NotificationObserverBag: @unchecked Sendable {
    private var observers: [any NSObjectProtocol] = []

    func add(_ observer: any NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif
