import Foundation

public enum AudioInputKind: String, Sendable, CaseIterable {
    case usb
    case wired
    case bluetoothHFP
    case builtIn
    case other
}

public struct AudioPort: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: AudioInputKind

    public init(id: String, name: String, kind: AudioInputKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct AudioSessionDiagnostics: Sendable, Equatable {
    public let isActive: Bool
    public let input: AudioPort?
    public let outputs: [AudioPort]
    public let sampleRate: Double

    public init(isActive: Bool, input: AudioPort?, outputs: [AudioPort], sampleRate: Double) {
        self.isActive = isActive
        self.input = input
        self.outputs = outputs
        self.sampleRate = sampleRate
    }

    public static let inactive = AudioSessionDiagnostics(isActive: false, input: nil, outputs: [], sampleRate: 0)
}

public enum AudioSessionEvent: Sendable, Equatable {
    case routeChanged(AudioSessionDiagnostics)
    case interruptionBegan
    case interruptionEnded(resumed: Bool)
}

public struct AudioInputPreferences: Sendable, Equatable {
    public var order: [AudioInputKind]
    public var allowsBluetoothHFP: Bool

    public init(
        order: [AudioInputKind] = [.usb, .wired, .builtIn],
        allowsBluetoothHFP: Bool = false
    ) {
        self.order = order
        self.allowsBluetoothHFP = allowsBluetoothHFP
    }

    public func resolve(from inputs: [AudioPort]) -> AudioPort? {
        order.lazy.compactMap { kind in
            guard kind != .bluetoothHFP || allowsBluetoothHFP else { return nil }
            return inputs.first { $0.kind == kind }
        }.first
    }
}

public enum AudioSessionBackendEvent: Sendable, Equatable {
    case routeChanged
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
}
public protocol AudioSessionBackend: Sendable {
    func configure(allowsBluetoothHFP: Bool) async throws
    func setActive(_ active: Bool) async throws
    func availableInputs() async -> [AudioPort]
    func selectInput(id: AudioPort.ID?) async throws
    func diagnostics(isActive: Bool) async -> AudioSessionDiagnostics
    func eventStream() async -> AsyncStream<AudioSessionBackendEvent>
}

public protocol AudioSessionDiagnosticsProviding: AudioSessionController {
    var diagnostics: AudioSessionDiagnostics { get async }
    var events: AsyncStream<AudioSessionEvent> { get async }
}

public actor ManagedAudioSession: AudioSessionDiagnosticsProviding {
    private let backend: any AudioSessionBackend
    private let preferences: AudioInputPreferences
    private let eventPair = AsyncStream<AudioSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    private var backendTask: Task<Void, Never>?
    private var latestDiagnostics = AudioSessionDiagnostics.inactive
    private var wantsActive = false
    private var sessionActive = false

    public init(backend: any AudioSessionBackend, preferences: AudioInputPreferences = AudioInputPreferences()) {
        self.backend = backend
        self.preferences = preferences
    }

    deinit {
        backendTask?.cancel()
        eventPair.continuation.finish()
    }

    public var diagnostics: AudioSessionDiagnostics {
        latestDiagnostics
    }

    public var events: AsyncStream<AudioSessionEvent> {
        eventPair.stream
    }

    public func activate() async throws {
        wantsActive = true
        do {
            try await backend.configure(allowsBluetoothHFP: preferences.allowsBluetoothHFP)
            try await backend.setActive(true)
            sessionActive = true
            try await selectPreferredInput()
            latestDiagnostics = await backend.diagnostics(isActive: true)
            startBackendEventsIfNeeded()
        } catch {
            wantsActive = false
            sessionActive = false
            try? await backend.setActive(false)
            latestDiagnostics = await backend.diagnostics(isActive: false)
            throw error
        }
    }

    public func deactivate() async {
        wantsActive = false
        sessionActive = false
        do {
            try await backend.setActive(false)
        } catch {
            // Deactivation is best-effort because this protocol is also used from teardown paths.
        }
        latestDiagnostics = await backend.diagnostics(isActive: false)
    }

    func handle(_ event: AudioSessionBackendEvent) async {
        switch event {
        case .routeChanged:
            await handleRouteChange()
        case .interruptionBegan:
            sessionActive = false
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventPair.continuation.yield(.interruptionBegan)
        case .interruptionEnded(let shouldResume):
            await handleInterruptionEnd(shouldResume: shouldResume)
        }
    }

    private func startBackendEventsIfNeeded() {
        guard backendTask == nil else { return }
        let backend = backend
        backendTask = Task { [weak self] in
            let stream = await backend.eventStream()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func selectPreferredInput() async throws {
        let input = preferences.resolve(from: await backend.availableInputs())
        let current = await backend.diagnostics(isActive: sessionActive).input
        guard input?.id != current?.id else { return }
        try await backend.selectInput(id: input?.id)
    }

    private func handleRouteChange() async {
        if wantsActive {
            try? await selectPreferredInput()
        }
        latestDiagnostics = await backend.diagnostics(isActive: sessionActive)
        eventPair.continuation.yield(.routeChanged(latestDiagnostics))
    }

    private func handleInterruptionEnd(shouldResume: Bool) async {
        guard wantsActive, shouldResume else {
            sessionActive = false
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventPair.continuation.yield(.interruptionEnded(resumed: false))
            return
        }
        do {
            try await backend.setActive(true)
            sessionActive = true
            try await selectPreferredInput()
            latestDiagnostics = await backend.diagnostics(isActive: true)
            eventPair.continuation.yield(.interruptionEnded(resumed: true))
        } catch {
            sessionActive = false
            try? await backend.setActive(false)
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventPair.continuation.yield(.interruptionEnded(resumed: false))
        }
    }
}
