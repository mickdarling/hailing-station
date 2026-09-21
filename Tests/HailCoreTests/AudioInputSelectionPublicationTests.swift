import Testing
@testable import HailCore

struct AudioInputSelectionPublicationTests {
    @Test func automaticSelectionAcceptsANewlyResolvedHigherPriorityInput() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let store = HoldingAudioInputPreferenceStore()
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await store.holdNextSaveCall()

        let selection = Task { try await controller.selectInput(id: nil) }
        await store.waitUntilSaveIsHeld()
        await backend.replaceInputs([.usb, .builtIn])
        await controller.handle(.routeChanged)
        await store.releaseHeldSave()
        try await selection.value

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.preferredInput == nil)
    }

    @Test func failedSelectionPublishesTheRouteThatInvalidatedAnOlderSnapshot() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = VolatileAudioInputPreferenceStore()
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.replaceInputs([.builtIn])
        await backend.holdDiagnosticsCall(after: 1)

        let routeChange = Task { await controller.handle(.routeChanged) }
        await backend.waitUntilDiagnosticsIsHeld()
        await #expect(throws: AudioInputSelectionError.unavailable("missing")) {
            try await controller.selectInput(id: "missing")
        }
        await backend.releaseHeldDiagnostics()
        await routeChange.value

        #expect(await backend.selectedInput == .builtIn)
        #expect(await controller.diagnostics.input == .builtIn)
    }

    @Test func sameGenerationReconciliationInvalidatesAnOlderRouteSnapshot() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let store = HoldingAudioInputPreferenceStore()
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await store.holdNextSaveCall()

        let selection = Task { try await controller.selectInput(id: nil) }
        await store.waitUntilSaveIsHeld()
        await backend.replaceInputs([.usb, .builtIn])
        await backend.holdDiagnosticsCall(after: 0)
        let routeChange = Task { await controller.handle(.routeChanged) }
        await backend.waitUntilDiagnosticsIsHeld()

        await store.releaseHeldSave()
        try await selection.value
        await backend.releaseHeldDiagnostics()
        await routeChange.value

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.diagnostics.input == .usb)
    }
}

private actor HoldingAudioInputPreferenceStore: AudioInputPreferenceStoring {
    private var stored: AudioPort?
    private var holdNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?

    func load() -> AudioPort? { stored }

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
