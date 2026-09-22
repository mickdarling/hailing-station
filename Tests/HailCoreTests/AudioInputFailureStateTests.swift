import Testing
@testable import HailCore

struct AudioInputFailureStateTests {
    @Test func expectedRemovalIsReportedAsFallbackNotFailure() async throws {
        let store = FailureStatePreferenceStore(initial: .usb)
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()

        await backend.replaceInputs([.builtIn])
        await controller.handle(.routeChanged)

        #expect(await controller.inputSelectionState == AudioInputSelectionState(
            resolution: .fallback,
            preferred: .usb,
            attempted: .builtIn,
            active: .builtIn
        ))
    }

    @Test func failedFallbackNamesPreferenceAttemptAndActualRoute() async throws {
        let store = FailureStatePreferenceStore(initial: .usb)
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()

        await backend.replaceInputs([.builtIn])
        await backend.failFutureSelections()
        await controller.handle(.routeChanged)

        let state = await controller.inputSelectionState
        #expect(state.resolution == .failed)
        #expect(state.preferred == .usb)
        #expect(state.attempted == .builtIn)
        #expect(state.active == nil)
        #expect(state.failureDescription != nil)
    }

    @Test func operatorCanRetryWithoutAnotherRouteNotification() async throws {
        let store = FailureStatePreferenceStore(initial: .usb)
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.replaceInputs([.builtIn])
        await backend.failFutureSelections()
        await controller.handle(.routeChanged)
        #expect(await controller.inputSelectionState.resolution == .failed)

        await backend.allowFutureSelections()
        try await controller.retryInputSelection()

        #expect(await controller.inputSelectionState.resolution == .fallback)
        #expect(await controller.inputSelectionState.preferred == .usb)
        #expect(await controller.inputSelectionState.active == .builtIn)
    }

    @Test func explicitMismatchPublishesFailedAttemptAndConfirmedActualInput() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.replaceInputsDuringNextSelection(with: [.usb])

        await #expect(throws: AudioInputSelectionError.routeMismatch(expected: .builtIn, actual: nil)) {
            try await controller.selectInput(id: AudioPort.builtIn.id)
        }

        let state = await controller.inputSelectionState
        #expect(state.resolution == .failed)
        #expect(state.attempted == .builtIn)
        #expect(state.active == .usb)
    }

    @Test func deactivationClearsFailureIntoInactiveState() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn], selectionFails: true)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())

        await #expect(throws: FakeAudioError.selectionFailed) {
            try await controller.activate()
        }

        #expect(await controller.inputSelectionState == .inactive)
    }

    @Test func backendSuccessWithoutRouteConfirmationRemainsFailed() async throws {
        let store = FailureStatePreferenceStore(initial: .usb)
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.replaceInputs([.builtIn])
        await backend.ignoreFutureSelections()

        await controller.handle(.routeChanged)

        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.attempted == .builtIn)
        #expect(await controller.inputSelectionState.active == nil)
    }

    @Test func missingAutomaticInputRetainsANilAttemptAsFailure() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.replaceInputs([])

        await #expect(throws: AudioInputSelectionError.noSelectableInput) {
            try await controller.selectInput(id: nil)
        }

        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.attempted == nil)
        #expect(await controller.inputSelectionState.active == nil)
    }

    @Test func staleFailureSnapshotCannotOverwriteDeactivation() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let store = FailureStatePreferenceStore(initial: .usb)
        let controller = ManagedAudioSession(backend: backend, preferenceStore: store)
        try await controller.activate()
        await backend.replaceInputs([.builtIn])
        await backend.failFutureSelections()
        await backend.holdDiagnosticsCall(after: 1)
        let routeChange = Task { await controller.handle(.routeChanged) }
        await backend.waitUntilDiagnosticsIsHeld()

        await controller.deactivate()
        await backend.releaseHeldDiagnostics()
        await routeChange.value

        #expect(await controller.inputSelectionState == .inactive)
        #expect(await controller.diagnostics.isActive == false)
    }

    @Test func suspendedRetryCannotOverwriteDeactivation() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.holdNextSelectionCall()
        let retry = Task { try await controller.retryInputSelection() }
        await backend.waitUntilSelectionIsHeld()

        await controller.deactivate()
        await backend.releaseHeldSelection()

        await #expect(throws: AudioInputSelectionError.superseded) { try await retry.value }
        #expect(await controller.inputSelectionState == .inactive)
        #expect(await controller.diagnostics.isActive == false)
    }

    @Test func suspendedRetryCannotOverwriteANewerExplicitSelection() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.holdNextSelectionCall()
        let retry = Task { try await controller.retryInputSelection() }
        await backend.waitUntilSelectionIsHeld()

        try await controller.selectInput(id: AudioPort.builtIn.id)
        await backend.releaseHeldSelection()

        await #expect(throws: AudioInputSelectionError.superseded) { try await retry.value }
        #expect(await controller.inputSelectionState.resolution == .confirmed)
        #expect(await controller.inputSelectionState.active == .builtIn)
    }
}

private actor FailureStatePreferenceStore: AudioInputPreferenceStoring {
    private var stored: AudioPort?

    init(initial: AudioPort? = nil) {
        stored = initial
    }

    func load() -> AudioPort? { stored }

    func save(_ port: AudioPort?) { stored = port }
}
