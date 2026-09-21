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

    @Test func selfInducedRouteEventCannotRestoreTheOldPreference() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FakeAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.emitRouteChangeOnFutureSelections()

        try await controller.selectInput(id: AudioPort.builtIn.id)

        #expect(await backend.selectedInput == .builtIn)
        #expect(await controller.preferredInput == .builtIn)
        #expect(await backend.selectionCount == 2)
    }

    @Test func laterInvocationSupersedesAnEarlierSuspendedLookup() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FakeAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.holdNextAvailableInputsCall()

        let earlier = Task { try await controller.selectInput(id: AudioPort.builtIn.id) }
        await backend.waitUntilInputLookupIsHeld()
        try await controller.selectInput(id: AudioPort.usb.id)
        await backend.releaseHeldInputLookup()

        await #expect(throws: AudioInputSelectionError.superseded) {
            try await earlier.value
        }
        #expect(await controller.preferredInput == .usb)
        #expect(await store.load() == .usb)
    }

    @Test func failedNewerLookupClearsTheSupersededPendingSelection() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FakeAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.holdNextSelectionCall()

        let earlier = Task { try await controller.selectInput(id: AudioPort.builtIn.id) }
        await backend.waitUntilSelectionIsHeld()
        await #expect(throws: AudioInputSelectionError.unavailable("missing")) {
            try await controller.selectInput(id: "missing")
        }
        await backend.releaseHeldSelection()

        await #expect(throws: AudioInputSelectionError.superseded) {
            try await earlier.value
        }
        #expect(await controller.preferredInput == .usb)
        #expect(await store.load() == .usb)
    }

    @Test func unplugDuringSelectionReconcilesToTheSavedPreference() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FakeAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.replaceInputsDuringNextSelection(with: [.usb])

        await #expect(throws: AudioInputSelectionError.routeMismatch(expected: .builtIn, actual: nil)) {
            try await controller.selectInput(id: AudioPort.builtIn.id)
        }

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.preferredInput == .usb)
    }

    @Test func unplugDuringPreferencePersistenceReportsTheReconciledRoute() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FakeAudioInputPreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await store.holdNextSaveCall()

        let selection = Task { try await controller.selectInput(id: AudioPort.builtIn.id) }
        await store.waitUntilSaveIsHeld()
        await backend.replaceInputs([.usb])
        await controller.handle(.routeChanged)
        await store.releaseHeldSave()

        await #expect(throws: AudioInputSelectionError.routeMismatch(expected: .builtIn, actual: .usb)) {
            try await selection.value
        }
        #expect(await backend.selectedInput == .usb)
    }

    @Test func automaticSelectionClearsTheConcretePreference() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FakeAudioInputPreferenceStore()
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        try await controller.selectInput(id: AudioPort.builtIn.id)

        try await controller.selectInput(id: nil)

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.preferredInput == nil)
        #expect(await store.load() == nil)
    }
}

private actor FakeAudioInputPreferenceStore: AudioInputPreferenceStoring {
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
