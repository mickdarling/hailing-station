import Testing
@testable import HailCore

struct AudioSessionLifecycleTests {
    @Test func deactivationSupersedesSuspendedConfiguration() async {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextConfigureCall()
        let activation = Task { try await controller.activate() }
        await backend.waitUntilConfigurationIsHeld()

        let deactivation = Task { await controller.deactivate() }
        await backend.releaseHeldConfiguration()

        await #expect(throws: AudioSessionLifecycleError.superseded) {
            try await activation.value
        }
        await deactivation.value
        #expect(await backend.activationHistory == [false, false])
        #expect(await controller.diagnostics.isActive == false)
    }

    @Test func deactivationReturnsInactiveAfterOlderActivationCompletes() async {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextActivationCall()
        let activation = Task { try await controller.activate() }
        await backend.waitUntilActivationIsHeld()

        let deactivation = Task { await controller.deactivate() }
        await backend.releaseHeldActivation()

        await #expect(throws: AudioSessionLifecycleError.superseded) {
            try await activation.value
        }
        await deactivation.value
        #expect(await backend.activationHistory == [true, false, false])
        #expect(await controller.diagnostics.isActive == false)
    }

    @Test func staleCleanupCannotDeactivateANewerActivation() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)
        await backend.holdNextActivationCall()
        let firstActivation = Task { try await controller.activate() }
        await backend.waitUntilActivationIsHeld()

        let deactivation = Task { await controller.deactivate() }
        let latestActivation = Task { try await controller.activate() }
        await backend.releaseHeldActivation()

        await #expect(throws: AudioSessionLifecycleError.superseded) {
            try await firstActivation.value
        }
        await deactivation.value
        try await latestActivation.value
        #expect(await backend.activationHistory == [true, true])
        #expect(await controller.diagnostics.isActive)
    }

    @Test func backendObservationStartsOnlyOnce() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let controller = ManagedAudioSession(backend: backend)

        try await controller.activate()
        try await controller.activate()

        await eventually { await backend.eventStreamRequestCount == 1 }
    }
}

private func eventually(
    _ predicate: @escaping @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<100 where !(await predicate()) {
        await Task.yield()
    }
    #expect(await predicate(), sourceLocation: sourceLocation)
}
