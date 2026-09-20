import Testing
@testable import HailCore

struct AudioInputSelectionTests {
    @Test func explicitSelectionPersistsAndOverridesKindOrder() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FakeAudioInputPreferenceStore()
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()

        try await controller.selectInput(id: AudioPort.builtIn.id)

        #expect(await backend.selectedInput == .builtIn)
        #expect(await controller.preferredInput == .builtIn)
        #expect(await store.load() == .builtIn)
    }

    @Test func unavailableExplicitSelectionFallsBackThenReturnsWhenAvailable() async throws {
        let store = FakeAudioInputPreferenceStore(initial: .usb)
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()

        #expect(await backend.selectedInput == .builtIn)
        #expect(await controller.preferredInput == .usb)

        await backend.replaceInputs([.usb, .builtIn])
        await controller.handle(.routeChanged)

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.preferredInput == .usb)
    }

    @Test func inputSelectionRejectsInactiveAndUnavailablePorts() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)

        await #expect(throws: AudioInputSelectionError.sessionInactive) {
            try await controller.selectInput(id: AudioPort.builtIn.id)
        }

        try await controller.activate()
        await #expect(throws: AudioInputSelectionError.unavailable("missing")) {
            try await controller.selectInput(id: "missing")
        }
    }
}

private actor FakeAudioInputPreferenceStore: AudioInputPreferenceStoring {
    private var stored: AudioPort?

    init(initial: AudioPort? = nil) {
        stored = initial
    }

    func load() -> AudioPort? {
        stored
    }

    func save(_ port: AudioPort?) {
        stored = port
    }
}
