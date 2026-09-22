import HailCore
import Observation

@MainActor
protocol AudioSceneCleanupCoordinating: AnyObject {
    func installSceneCleanup(_ cleanup: @escaping @MainActor () async -> Void)
    func removeSceneCleanup()
}

/// One UI-facing audio-route subscription shared by the station and diagnostics screens.
@MainActor
@Observable
final class AudioRouteModel: AudioInputSelectionProviding, AudioSceneCleanupCoordinating {
    let controller: any AudioInputSelectionProviding
    private var sceneCleanup: (@MainActor () async -> Void)?

    private(set) var diagnostics = AudioSessionDiagnostics.inactive
    private(set) var inputs: [AudioPort] = []
    private(set) var preferredInput: AudioPort?
    private(set) var selectionState = AudioInputSelectionState.inactive
    private(set) var status = "Audio inactive"

    init(controller: any AudioInputSelectionProviding) {
        self.controller = controller
    }

    func observe() async {
        await refresh()
        for await event in await controller.events {
            guard !Task.isCancelled else { return }
            await refresh()
            switch event {
            case .routeChanged:
                status = routeChangeStatus
            case .interruptionBegan:
                status = "Audio interrupted"
            case .interruptionEnded(let resumed):
                status = resumed ? "Audio resumed" : "Audio inactive"
            }
        }
    }

    func activate() async throws {
        do {
            try await controller.activate()
            await refresh()
            status = activeInputStatus
        } catch {
            await refresh()
            status = "Activation failed: \(error.localizedDescription)"
            throw error
        }
    }

    func deactivate() async {
        await controller.deactivate()
        await refresh()
        status = "Audio inactive"
    }

    func installSceneCleanup(_ cleanup: @escaping @MainActor () async -> Void) { sceneCleanup = cleanup }
    func removeSceneCleanup() { sceneCleanup = nil }
    func sceneBecameInactive() async {
        await sceneCleanup?()
        if diagnostics.isActive { await deactivate() }
    }

    func select(_ input: AudioPort?) async {
        let name = input?.name ?? "Automatic"
        do {
            if !diagnostics.isActive { try await controller.activate() }
            try await selectInput(id: input?.id)
        } catch {
            await refresh()
            status = "Could not select \(name): \(error.localizedDescription)"
        }
    }

    func retry() async {
        do {
            if !diagnostics.isActive { try await controller.activate() }
            try await retryInputSelection()
        } catch {
            await refresh()
            status = "Retry failed: \(error.localizedDescription)"
        }
    }

    var events: AsyncStream<AudioSessionEvent> {
        get async { await controller.events }
    }

    var inputSelectionState: AudioInputSelectionState {
        get async { await controller.inputSelectionState }
    }

    func selectInput(id: AudioPort.ID?) async throws {
        try await controller.selectInput(id: id)
        await refresh()
        status = preferredInput.map { "Using \($0.name)" } ?? activeInputStatus
    }

    func retryInputSelection() async throws {
        try await controller.retryInputSelection()
        await refresh()
    }

    func refresh() async {
        diagnostics = await controller.diagnostics
        inputs = await controller.availableInputs
        preferredInput = await controller.preferredInput
        selectionState = await controller.inputSelectionState
        status = diagnostics.isActive ? inputStateStatus : "Audio inactive"
    }

    var availableInputs: [AudioPort] { inputs }

    var inputName: String {
        diagnostics.input?.name ?? preferredInput?.name ?? "Automatic"
    }

    var outputName: String {
        let names = diagnostics.outputs.map(\.name)
        return names.isEmpty ? "System output" : names.joined(separator: ", ")
    }

    var preferredStateDescription: String? {
        guard let preferredInput, preferredInput.id != diagnostics.input?.id else { return nil }
        let availability = inputs.contains { $0.id == preferredInput.id }
        return "\(preferredInput.name) · \(availability ? "not active" : "unavailable")"
    }

    var hasInputFailure: Bool { selectionState.resolution == .failed }

    var inputFailureDescription: String? { selectionState.failureDescription }

    var inputAccessibilityLabel: String {
        let active = diagnostics.input?.name ?? "no active microphone"
        if hasInputFailure {
            let attempted = selectionState.attempted?.name ?? "automatic selection"
            return "Microphone, \(active). Could not apply \(attempted). Choose a microphone or retry."
        }
        guard let preferredStateDescription else {
            return "Microphone, \(active). Choose microphone."
        }
        return "Microphone, \(active). Preferred \(preferredStateDescription). Choose microphone."
    }

    var sampleRate: String {
        diagnostics.sampleRate == 0 ? "—" : "\(Int(diagnostics.sampleRate)) Hz"
    }

    private var routeChangeStatus: String {
        hasInputFailure ? inputStateStatus : "Audio route changed; \(inputStateStatus)"
    }

    private var activeInputStatus: String {
        guard let preferredStateDescription else {
            return diagnostics.input.map { "Using \($0.name)" } ?? "Active with no microphone"
        }
        return "Active; preferred \(preferredStateDescription)"
    }

    private var inputStateStatus: String {
        switch selectionState.resolution {
        case .inactive:
            return "Audio inactive"
        case .automatic:
            return diagnostics.input.map { "Using \($0.name) automatically" } ?? "No microphone active"
        case .confirmed:
            return diagnostics.input.map { "Using \($0.name)" } ?? "Preferred microphone is not active"
        case .fallback:
            let active = diagnostics.input?.name ?? "fallback input"
            let preferred = preferredInput?.name ?? "input"
            return "Using \(active); preferred \(preferred) unavailable"
        case .failed:
            return "Microphone needs attention: \(inputFailureDescription ?? "route request failed")"
        }
    }
}
