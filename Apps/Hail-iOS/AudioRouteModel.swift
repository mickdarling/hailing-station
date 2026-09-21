import HailCore
import Observation

/// One UI-facing audio-route subscription shared by the station and diagnostics screens.
@MainActor
@Observable
final class AudioRouteModel: AudioSessionDiagnosticsProviding {
    let controller: any AudioSessionDiagnosticsProviding

    private(set) var diagnostics = AudioSessionDiagnostics.inactive
    private(set) var inputs: [AudioPort] = []
    private(set) var preferredInput: AudioPort?
    private(set) var status = "Audio inactive"

    init(controller: any AudioSessionDiagnosticsProviding) {
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

    func select(_ input: AudioPort?) async {
        let name = input?.name ?? "Automatic"
        do {
            try await selectInput(id: input?.id)
        } catch {
            await refresh()
            status = "Could not select \(name): \(error.localizedDescription)"
        }
    }

    var events: AsyncStream<AudioSessionEvent> {
        get async { await controller.events }
    }

    func selectInput(id: AudioPort.ID?) async throws {
        try await controller.selectInput(id: id)
        await refresh()
        status = preferredInput.map { "Using \($0.name)" } ?? activeInputStatus
    }

    func refresh() async {
        diagnostics = await controller.diagnostics
        inputs = await controller.availableInputs
        preferredInput = await controller.preferredInput
        status = diagnostics.isActive ? activeInputStatus : "Audio inactive"
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

    var inputAccessibilityLabel: String {
        let active = diagnostics.input?.name ?? "no active microphone"
        guard let preferredStateDescription else {
            return "Microphone, \(active). Choose microphone."
        }
        return "Microphone, \(active). Preferred \(preferredStateDescription). Choose microphone."
    }

    var sampleRate: String {
        diagnostics.sampleRate == 0 ? "—" : "\(Int(diagnostics.sampleRate)) Hz"
    }

    private var routeChangeStatus: String {
        guard let preferredStateDescription else { return "Audio route changed" }
        return "Route changed; preferred \(preferredStateDescription)"
    }

    private var activeInputStatus: String {
        guard let preferredStateDescription else {
            return diagnostics.input.map { "Using \($0.name)" } ?? "Active with no microphone"
        }
        return "Active; preferred \(preferredStateDescription)"
    }
}
