import Testing
@testable import HailCore

struct RouteChangeHandlingTests {
    @Test func routeChangeReappliesPreferenceAndPublishesDiagnostics() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(backend: backend)
        try await controller.activate()
        #expect(await backend.selectedInput == .usb)

        await backend.replaceInputs([.builtIn])
        await controller.handle(.routeChanged)

        #expect(await backend.selectedInput == .builtIn)
        #expect(await controller.diagnostics.input == .builtIn)
        #expect(await controller.diagnostics.isActive)
    }

    @Test func outputOnlyRouteChangeDoesNotReselectTheCurrentInput() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb])
        let controller = ManagedAudioSession(backend: backend)
        try await controller.activate()
        #expect(await backend.selectionCount == 1)

        await controller.handle(.routeChanged)

        #expect(await backend.selectionCount == 1)
        #expect(await controller.diagnostics.input == .usb)
    }

    @Test func interruptionResumesOnlyWhenTheSystemAllowsIt() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb])
        let controller = ManagedAudioSession(backend: backend)
        try await controller.activate()

        await controller.handle(.interruptionBegan)
        #expect(await controller.diagnostics.isActive == false)

        await controller.handle(.interruptionEnded(shouldResume: true))
        #expect(await controller.diagnostics.isActive)
        #expect(await backend.activationHistory == [true, true])
    }

    @Test func routeChangeDuringInterruptionRemainsInactive() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb])
        let controller = ManagedAudioSession(backend: backend)
        try await controller.activate()

        await controller.handle(.interruptionBegan)
        await controller.handle(.routeChanged)

        #expect(await controller.diagnostics.isActive == false)
    }

    @Test func deactivatedSessionDoesNotResumeAfterInterruption() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        try await controller.activate()
        await controller.deactivate()
        await controller.handle(.interruptionEnded(shouldResume: true))

        #expect(await controller.diagnostics.isActive == false)
        #expect(await backend.activationHistory == [true, false])
    }

    @Test func failedPreferenceSelectionDeactivatesTheSession() async {
        let backend = FakeAudioSessionBackend(inputs: [.usb], selectionFails: true)
        let controller = ManagedAudioSession(backend: backend)

        await #expect(throws: FakeAudioError.selectionFailed) {
            try await controller.activate()
        }
        #expect(await backend.activationHistory == [true, false])
        #expect(await controller.diagnostics.isActive == false)
    }

    @Test func failedSelectionWhileResumingDeactivatesTheSession() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb])
        let controller = ManagedAudioSession(backend: backend)
        try await controller.activate()
        await controller.handle(.interruptionBegan)
        await backend.replaceInputs([.builtIn])
        await backend.failFutureSelections()

        await controller.handle(.interruptionEnded(shouldResume: true))

        #expect(await backend.activationHistory == [true, true, false])
        #expect(await controller.diagnostics.isActive == false)
    }
}

private enum FakeAudioError: Error {
    case selectionFailed
}

actor FakeAudioSessionBackend: AudioSessionBackend {
    static let usb = AudioPort(id: "usb", name: "Wireless Mic Rx", kind: .usb)
    static let builtIn = AudioPort(id: "built-in", name: "iPad Microphone", kind: .builtIn)

    private var inputs: [AudioPort]
    private var selectionFails: Bool
    private(set) var selectedInput: AudioPort?
    private(set) var selectionCount = 0
    private(set) var activationHistory: [Bool] = []
    private var active = false

    init(inputs: [AudioPort], selectionFails: Bool = false) {
        self.inputs = inputs
        self.selectionFails = selectionFails
    }

    func configure(allowsBluetoothHFP: Bool) async throws {}

    func setActive(_ active: Bool) async throws {
        self.active = active
        activationHistory.append(active)
    }

    func availableInputs() async -> [AudioPort] {
        inputs
    }

    func selectInput(id: AudioPort.ID?) async throws {
        if selectionFails { throw FakeAudioError.selectionFailed }
        selectionCount += 1
        selectedInput = inputs.first { $0.id == id }
    }

    func diagnostics(isActive: Bool) async -> AudioSessionDiagnostics {
        AudioSessionDiagnostics(
            isActive: isActive,
            input: selectedInput,
            outputs: [AudioPort(id: "speaker", name: "Speaker", kind: .other)],
            sampleRate: 48_000
        )
    }

    func eventStream() async -> AsyncStream<AudioSessionBackendEvent> {
        AsyncStream { _ in }
    }

    func replaceInputs(_ inputs: [AudioPort]) {
        self.inputs = inputs
        if let selectedInput, !inputs.contains(selectedInput) {
            self.selectedInput = nil
        }
    }

    func failFutureSelections() {
        selectionFails = true
    }
}

extension AudioPort {
    static let usb = AudioPort(id: "usb", name: "Wireless Mic Rx", kind: .usb)
    static let builtIn = AudioPort(id: "built-in", name: "iPad Microphone", kind: .builtIn)
}
