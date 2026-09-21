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
