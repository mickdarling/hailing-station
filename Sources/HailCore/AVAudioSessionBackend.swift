#if os(iOS)
import AVFoundation
import Foundation
import os

@MainActor
public final class AVAudioSessionBackend: AudioSessionBackend {
    private static let log = Logger(subsystem: "com.mickdarling.hailing-station", category: "output-route")
    let session: AVAudioSession
    private let events: AsyncStream<AudioSessionBackendEvent>
    private let continuation: AsyncStream<AudioSessionBackendEvent>.Continuation
    private let observers = NotificationObserverBag()
    let routing: AudioOutputSessionRouting

    public convenience init() {
        self.init(routing: .shared)
    }

    init(routing: AudioOutputSessionRouting) {
        self.routing = routing
        session = routing.session
        let pair = AsyncStream<AudioSessionBackendEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = pair.stream
        continuation = pair.continuation
        observeNotifications()
    }

    deinit {
        continuation.finish()
    }

    public func configure(allowsBluetoothHFP: Bool) async throws {
        // Capture takes ownership on activation and then applies its saved microphone selection.
        try routing.prepareBackendCategory(allowsBluetoothHFP: allowsBluetoothHFP, source: .capturePreparation)
    }

    public func setActive(_ active: Bool) async throws {
        try routing.setCaptureActive(active)
    }

    public func availableInputs() async -> [AudioPort] {
        (session.availableInputs ?? []).filter { permitsInput($0) }.map(Self.port)
    }

    public func selectInput(id: AudioPort.ID?) async throws {
        guard session.category != .playback else { throw AudioInputSelectionError.sessionInactive }
        let selected = session.availableInputs?.first { $0.uid == id }
        if let selected, !permitsInput(selected) { throw AudioInputSelectionError.unavailable(selected.uid) }
        try routing.select(selected)
    }

    private func permitsInput(_ port: AVAudioSessionPortDescription) -> Bool {
        port.portType != .bluetoothHFP || !routing.driver.state.holdsBuiltInOutput
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

    static func logRouteDecision(_ reason: AudioOutputRoutePolicy.DecisionReason) {
        // Fixed messages only: no device names, UIDs, or route payloads in field logs (#852).
        switch reason {
        case .repairRequested, .speakerFallback, .appOperation, .ambiguous: break
        case .userChoiceAssumed: log.info("repair not attempted: user choice assumed")
        case .noHardwareEpisode: log.info("repair not attempted: no hardware episode")
        case .keepalive: log.info("repair not attempted: keepalive")
        case .unsupportedCategory: log.info("repair not attempted: unsupported category")
        case .noExternalEvidence: log.info("repair not attempted: no external evidence")
        case .externalOutputActive: log.info("repair not attempted: external output active")
        case .awaitingRoute: log.info("repair not attempted: awaiting route")
        }
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

    static func port(_ description: AVAudioSessionPortDescription) -> AudioPort {
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

// The lifecycle calls this overload after activation. The existing resolver verifies the selected input,
// including its no-write path. Settle output once that selection succeeds, before activate() returns.
extension ManagedAudioSession {
    @discardableResult
    func selectPreferredInput() async throws -> AudioSessionDiagnostics {
        let selected = try await selectPreferredInput(expectedGeneration: nil)
        if let backend = backend as? AVAudioSessionBackend {
            await backend.routing.inputSelectionFinished()
        }
        return selected
    }
}

final class NotificationObserverBag: @unchecked Sendable {
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
