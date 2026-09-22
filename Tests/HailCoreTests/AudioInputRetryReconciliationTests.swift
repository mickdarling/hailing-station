import Testing
@testable import HailCore

struct AudioInputRetryReconciliationTests {
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

    @Test func thrownBackendFailureAfterDeactivationRemainsSuperseded() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.holdNextSelectionCall()
        let retry = Task { try await controller.retryInputSelection() }
        await backend.waitUntilSelectionIsHeld()

        await controller.deactivate()
        await backend.failFutureSelections()
        await backend.releaseHeldSelection()

        await #expect(throws: AudioInputSelectionError.superseded) { try await retry.value }
        #expect(await controller.inputSelectionState == .inactive)
        await backend.allowFutureSelections()
        try await controller.activate()
        #expect(await controller.inputSelectionState.resolution == .automatic)
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

    @Test func retryDrainsARouteChangeThatArrivesWhileSelectionIsSuspended() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.replaceInputsDuringNextSelection(with: [.usb, .builtIn])

        try await controller.retryInputSelection()

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.inputSelectionState.resolution == .automatic)
        #expect(await controller.inputSelectionState.active == .usb)
    }

    @Test func retryAcceptsRestoredSavedPreferenceInsteadOfItsInitialFallback() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(
            backend: backend,
            preferenceStore: FailureStatePreferenceStore(initial: .usb)
        )
        try await controller.activate()
        await backend.replaceInputsDuringNextSelection(with: [.usb, .builtIn])

        try await controller.retryInputSelection()

        #expect(await controller.inputSelectionState.resolution == .confirmed)
        #expect(await controller.inputSelectionState.active == .usb)
    }

    @Test func retryAppliesHigherPriorityInputDiscoveredDuringFinalConfirmation() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.replaceInputs([.usb, .builtIn], afterAvailableInputCalls: 1)

        try await controller.retryInputSelection()

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.inputSelectionState.resolution == .automatic)
        #expect(await controller.inputSelectionState.active == .usb)
    }

    @Test func retryRetainsFailureUntilFinalDiagnosticsConfirmRecovery() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await #expect(throws: AudioInputSelectionError.unavailable("missing")) {
            try await controller.selectInput(id: "missing")
        }
        await backend.holdDiagnosticsCall(after: 1)
        let retry = Task { try await controller.retryInputSelection() }
        await backend.waitUntilDiagnosticsIsHeld()

        #expect(await controller.inputSelectionState.resolution == .failed)
        await backend.releaseHeldDiagnostics()
        try await retry.value
        #expect(await controller.inputSelectionState.resolution == .automatic)
    }

    @Test func retryPropagatesFailureFromQueuedRouteReconciliation() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.replaceInputsDuringNextSelection(with: [.usb, .builtIn])
        await backend.failSelectionsAfterNextInputReplacement()

        await #expect(throws: AudioInputSelectionError.routeMismatch(expected: .usb, actual: .builtIn)) {
            try await controller.retryInputSelection()
        }

        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.attempted == .usb)
        #expect(await controller.inputSelectionState.active == .builtIn)
    }

    @Test func retryWithNoSelectableInputPublishesTheNewFailure() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.replaceInputs([])

        await #expect(throws: AudioInputSelectionError.noSelectableInput) {
            try await controller.retryInputSelection()
        }

        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.attempted == nil)
        #expect(await controller.inputSelectionState.active == nil)
    }

    @Test func reconciliationFailureRetainsThePortActuallyAttempted() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(
            backend: backend,
            preferenceStore: FailureStatePreferenceStore(initial: .usb)
        )
        try await controller.activate()
        await backend.replaceInputs([.usb, .builtIn])
        await backend.holdNextSelectionCall()
        let routeChange = Task { await controller.handle(.routeChanged) }
        await backend.waitUntilSelectionIsHeld()
        await backend.replaceInputs([.builtIn])
        await backend.failFutureSelections()
        await backend.releaseHeldSelection()
        await routeChange.value

        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.attempted == .usb)
    }
}
