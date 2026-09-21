import Testing
@testable import HailCore

struct AudioInputSelectionConcurrencyTests {
    @Test func supersededSaveCannotOverwriteTheLatestPreference() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = SuspendingAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await store.holdNextSaveCall()

        let earlier = Task { try await controller.selectInput(id: AudioPort.builtIn.id) }
        await store.waitUntilSaveIsHeld()
        let later = Task { try await controller.selectInput(id: AudioPort.usb.id) }
        await store.releaseHeldSave()

        await #expect(throws: AudioInputSelectionError.superseded) {
            try await earlier.value
        }
        try await later.value
        #expect(await controller.preferredInput == .usb)
        #expect(await store.load() == .usb)
    }

    @Test func staleBackendSelectionReappliesTheLatestPreferenceWhenItReturns() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = SuspendingAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.holdNextSelectionCall()

        let earlier = Task { try await controller.selectInput(id: AudioPort.builtIn.id) }
        await backend.waitUntilSelectionIsHeld()
        try await controller.selectInput(id: AudioPort.usb.id)
        await backend.releaseHeldSelection()

        await #expect(throws: AudioInputSelectionError.superseded) {
            try await earlier.value
        }
        #expect(await backend.selectedInput == .usb)
        #expect(await controller.preferredInput == .usb)
    }

    @Test func suspendedRouteReapplyCannotOverrideANewerUserSelection() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = SuspendingAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.holdNextAvailableInputsCall()

        let routeChange = Task { await controller.handle(.routeChanged) }
        await backend.waitUntilInputLookupIsHeld()
        try await controller.selectInput(id: AudioPort.builtIn.id)
        await backend.releaseHeldInputLookup()
        await routeChange.value

        #expect(await backend.selectedInput == .builtIn)
        #expect(await controller.preferredInput == .builtIn)
    }

    @Test func failedSupersedingRequestRepairsTheEscapedOlderSave() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = SuspendingAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await store.holdNextSaveCall()

        let earlier = Task { try await controller.selectInput(id: AudioPort.builtIn.id) }
        await store.waitUntilSaveIsHeld()
        await #expect(throws: AudioInputSelectionError.unavailable("missing")) {
            try await controller.selectInput(id: "missing")
        }
        await store.releaseHeldSave()

        await #expect(throws: AudioInputSelectionError.superseded) {
            try await earlier.value
        }
        #expect(await controller.preferredInput == .usb)
        #expect(await store.load() == .usb)
    }

    @Test func routeQueuedDuringFinalDiagnosticsDrainsWhenSelectionBecomesIdle() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let store = SuspendingAudioInputPreferenceStore()
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await store.holdNextSaveCall()

        let selection = Task { try await controller.selectInput(id: nil) }
        await store.waitUntilSaveIsHeld()
        await controller.handle(.routeChanged)
        await backend.holdDiagnosticsCall(after: 1)
        await store.releaseHeldSave()
        await backend.waitUntilDiagnosticsIsHeld()

        await backend.replaceInputs([.usb, .builtIn])
        await controller.handle(.routeChanged)
        await backend.releaseHeldDiagnostics()
        try await selection.value

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.preferredInput == nil)
    }
}

private actor SuspendingAudioInputPreferenceStore: AudioInputPreferenceStoring {
    private var stored: AudioPort?
    private var holdNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?

    init(initial: AudioPort? = nil) {
        stored = initial
    }

    func load() -> AudioPort? {
        stored
    }

    func save(_ port: AudioPort?) async {
        if holdNextSave {
            holdNextSave = false
            await withCheckedContinuation { continuation in
                heldSave = continuation
            }
        }
        stored = port
    }

    func holdNextSaveCall() { holdNextSave = true }

    func waitUntilSaveIsHeld() async {
        while heldSave == nil {
            await Task.yield()
        }
    }

    func releaseHeldSave() {
        let continuation = heldSave
        heldSave = nil
        continuation?.resume()
    }
}
