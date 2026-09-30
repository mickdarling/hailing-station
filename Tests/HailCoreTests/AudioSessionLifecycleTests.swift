import Testing
@testable import HailCore

struct AudioSessionLifecycleTests {
    @Test func deactivationSupersedesSuspendedConfiguration() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextConfigureCall()
        var work = AudioLifecycleTestWork(backend: backend)
        let activation = work.activate(controller)
        await backend.waitUntilConfigurationIsHeld()

        do {
            let deactivation = work.deactivate(controller)
            try await acknowledgeAudioLifecycleAdmission(controller, generation: 2, wantsActive: false, waiters: 1)
            await backend.releaseHeldConfiguration()
            await #expect(throws: AudioSessionLifecycleError.superseded) { try await activation.value }
            await deactivation.value
            #expect(await backend.activationHistory == [false, false])
            #expect(await controller.diagnostics.isActive == false)
        } catch {
            await work.releaseAndDrain()
            throw error
        }
        await work.releaseAndDrain()
    }

    @Test func deactivationReturnsInactiveAfterOlderActivationCompletes() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextActivationCall()
        var work = AudioLifecycleTestWork(backend: backend)
        let activation = work.activate(controller)
        await backend.waitUntilActivationIsHeld()

        do {
            let deactivation = work.deactivate(controller)
            try await acknowledgeAudioLifecycleAdmission(controller, generation: 2, wantsActive: false, waiters: 1)
            await backend.releaseHeldActivation()
            await #expect(throws: AudioSessionLifecycleError.superseded) { try await activation.value }
            await deactivation.value
            #expect(await backend.activationHistory == [true, false, false])
            #expect(await controller.diagnostics.isActive == false)
        } catch {
            await work.releaseAndDrain()
            throw error
        }
        await work.releaseAndDrain()
    }

    @Test func staleCleanupCannotDeactivateANewerActivation() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextActivationCall()
        var work = AudioLifecycleTestWork(backend: backend)
        let firstActivation = work.activate(controller)
        await backend.waitUntilActivationIsHeld()

        do {
            let deactivation = work.deactivate(controller)
            try await acknowledgeAudioLifecycleAdmission(controller, generation: 2, wantsActive: false, waiters: 1)
            let latestActivation = work.activate(controller)
            try await acknowledgeAudioLifecycleAdmission(controller, generation: 3, wantsActive: true, waiters: 2)
            await backend.releaseHeldActivation()
            await #expect(throws: AudioSessionLifecycleError.superseded) { try await firstActivation.value }
            await deactivation.value
            try await latestActivation.value
            #expect(await backend.activationHistory == [true, true])
            #expect(await controller.diagnostics.isActive)
        } catch {
            await work.releaseAndDrain()
            throw error
        }
        await work.releaseAndDrain()
    }

    @Test func laterAdmittedDeactivationSupersedesBothActivations() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextActivationCall()
        var work = AudioLifecycleTestWork(backend: backend)
        let firstActivation = work.activate(controller)
        await backend.waitUntilActivationIsHeld()

        do {
            let secondActivation = work.activate(controller)
            try await acknowledgeAudioLifecycleAdmission(controller, generation: 2, wantsActive: true, waiters: 1)
            let deactivation = work.deactivate(controller)
            try await acknowledgeAudioLifecycleAdmission(controller, generation: 3, wantsActive: false, waiters: 2)
            await backend.releaseHeldActivation()
            await #expect(throws: AudioSessionLifecycleError.superseded) { try await firstActivation.value }
            await #expect(throws: AudioSessionLifecycleError.superseded) { try await secondActivation.value }
            await deactivation.value
            // Each superseded activation cleans up, followed by the admitted deactivation.
            let history = await backend.activationHistory
            #expect(history == [true, false, false, false])
            #expect(await controller.diagnostics.isActive == false)
        } catch {
            await work.releaseAndDrain()
            throw error
        }
        await work.releaseAndDrain()
    }

    @Test func expiredAdmissionWatchdogStillReleasesAndDrainsHeldWork() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextActivationCall()
        var work = AudioLifecycleTestWork(backend: backend)
        let activation = work.activate(controller)
        await backend.waitUntilActivationIsHeld()
        await #expect(throws: AudioLifecycleAdmissionTestError.watchdogExpired) {
            try await acknowledgeAudioLifecycleAdmission(controller, generation: 2, wantsActive: false,
                                                         waiters: 1, timeout: .zero)
        }
        await work.releaseAndDrain()
        try await activation.value
        #expect(await backend.activationHistory == [true])
        #expect(await controller.diagnostics.isActive)
    }

    @Test func backendObservationStartsOnlyOnce() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)

        try await controller.activate()
        try await controller.activate()

        try await waitForAudioTestState { await backend.eventStreamRequestCount == 1 }
    }
}
