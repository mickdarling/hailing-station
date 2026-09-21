#if os(iOS)
import AVFoundation
import Foundation

@MainActor
public final class AVAudioSessionBackend: AudioSessionBackend {
    private let session: AVAudioSession
    private let events: AsyncStream<AudioSessionBackendEvent>
    private let continuation: AsyncStream<AudioSessionBackendEvent>.Continuation
    private let observers = NotificationObserverBag()

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
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker]
        if allowsBluetoothHFP {
            options.insert(.allowBluetoothHFP)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
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
        ) { [continuation] _ in
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
