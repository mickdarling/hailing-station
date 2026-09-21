public import Foundation

public enum AudioInputKind: String, Sendable, CaseIterable, Codable {
    case usb
    case wired
    case bluetoothHFP
    case builtIn
    case other
}

public struct AudioPort: Sendable, Equatable, Identifiable, Codable {
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
    var availableInputs: [AudioPort] { get async }
    var preferredInput: AudioPort? { get async }
    func selectInput(id: AudioPort.ID?) async throws
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

public protocol AudioInputPreferenceStoring: Sendable {
    func load() async -> AudioPort?
    func save(_ port: AudioPort?) async
}

public actor UserDefaultsAudioInputPreferenceStore: AudioInputPreferenceStoring {
    private let key: String
    private let suiteName: String?

    public init(
        key: String = "hailing-station.preferred-audio-input",
        suiteName: String? = nil
    ) {
        self.key = key
        self.suiteName = suiteName
    }

    public func load() -> AudioPort? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AudioPort.self, from: data)
    }

    public func save(_ port: AudioPort?) {
        guard let port, let data = try? JSONEncoder().encode(port) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}

public enum AudioInputSelectionError: Error, Sendable, Equatable, LocalizedError {
    case noSelectableInput
    case sessionInactive
    case superseded
    case unavailable(AudioPort.ID)
    case routeMismatch(expected: AudioPort, actual: AudioPort?)

    public var errorDescription: String? {
        switch self {
        case .noSelectableInput:
            "No supported microphone is currently available."
        case .sessionInactive:
            "Activate the audio session before choosing a microphone."
        case .superseded:
            "A newer microphone selection replaced this request."
        case .unavailable:
            "That microphone is no longer available."
        case .routeMismatch(let expected, let actual):
            "Requested \(expected.name), but iOS kept \(actual?.name ?? "no active microphone")."
        }
    }
}
