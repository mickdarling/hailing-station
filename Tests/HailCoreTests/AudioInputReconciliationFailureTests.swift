import Testing
@testable import HailCore

struct AudioInputReconciliationFailureTests {
    @Test func automaticSelectionPropagatesQueuedReconciliationFailure() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.replaceInputsDuringNextSelection(with: [.usb, .builtIn])
        await backend.failSelectionsAfterNextInputReplacement()

        await #expect(throws: AudioInputSelectionError.routeMismatch(expected: .usb, actual: .builtIn)) {
            try await controller.selectInput(id: nil)
        }

        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.attempted == .usb)
        #expect(await controller.inputSelectionState.active == .builtIn)
    }

    @Test func staleThrownReconciliationCannotFailANewerSelection() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(
            backend: backend,
            preferenceStore: FailureStatePreferenceStore(initial: .usb)
        )
        try await controller.activate()
        await backend.replaceInputs([.builtIn])
        await backend.holdNextSelectionCall()
        let routeChange = Task { await controller.handle(.routeChanged) }
        await backend.waitUntilSelectionIsHeld()

        try await controller.selectInput(id: AudioPort.builtIn.id)
        await backend.failFutureSelections()
        await backend.releaseHeldSelection()
        await routeChange.value

        #expect(await controller.inputSelectionState.resolution == .confirmed)
        #expect(await controller.inputSelectionState.failureDescription == nil)
        #expect(await controller.inputSelectionState.active == .builtIn)
    }

    @Test func cleanupRetainsTheNewestReconciliationFailure() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.holdDiagnosticsCall(after: 0)
        let selection = Task { try await controller.selectInput(id: "missing") }
        await backend.waitUntilDiagnosticsIsHeld()

        await backend.replaceInputs([.usb, .builtIn])
        await controller.handle(.routeChanged)
        await backend.failFutureSelections()
        await backend.releaseHeldDiagnostics()

        await #expect(throws: AudioInputSelectionError.unavailable("missing")) { try await selection.value }
        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.attempted == .usb)
    }

    @Test func confirmedDifferentFallbackClearsAnEarlierRouteFailure() async throws {
        let wired = AudioPort(id: "wired", name: "Wired Microphone", kind: .wired)
        let backend = FakeAudioSessionBackend(inputs: [.usb, .builtIn])
        let controller = ManagedAudioSession(
            backend: backend,
            preferenceStore: FailureStatePreferenceStore(initial: .usb)
        )
        try await controller.activate()
        await backend.replaceInputs([.builtIn])
        await backend.failFutureSelections()
        await controller.handle(.routeChanged)
        #expect(await controller.inputSelectionState.resolution == .failed)

        await backend.allowFutureSelections()
        await backend.replaceInputs([wired, .builtIn])
        await controller.handle(.routeChanged)

        #expect(await controller.inputSelectionState.resolution == .fallback)
        #expect(await controller.inputSelectionState.failureDescription == nil)
        #expect(await controller.inputSelectionState.active == wired)
    }

    @Test func retryReconfirmsAfterANewerRoutePublishesDuringFinalDiagnostics() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.holdDiagnosticsCall(after: 1)
        let retry = Task { try await controller.retryInputSelection() }
        await backend.waitUntilDiagnosticsIsHeld()

        await backend.replaceInputs([.usb, .builtIn])
        await controller.handle(.routeChanged)
        await backend.releaseHeldDiagnostics()
        try await retry.value

        #expect(await backend.selectedInput == .usb)
        #expect(await controller.inputSelectionState.resolution == .automatic)
        #expect(await controller.inputSelectionState.active == .usb)
    }

    @Test func cleanupNeverPublishesSuccessForTheRequestThatJustFailed() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend, preferenceStore: FailureStatePreferenceStore())
        try await controller.activate()
        await backend.holdNextAvailableInputsCall()
        let selection = Task { try await controller.selectInput(id: "missing") }
        await backend.waitUntilInputLookupIsHeld()

        await controller.handle(.routeChanged)
        await backend.holdDiagnosticsCall(after: 2)
        await backend.releaseHeldInputLookup()
        await backend.waitUntilDiagnosticsIsHeld()

        #expect(await controller.inputSelectionState.resolution == .failed)
        #expect(await controller.inputSelectionState.failureDescription != nil)
        await backend.releaseHeldDiagnostics()
        await #expect(throws: AudioInputSelectionError.unavailable("missing")) { try await selection.value }
    }
}
