public import Foundation

public enum AudioSessionLifecycleError: Error, Sendable, Equatable, LocalizedError {
    case superseded

    public var errorDescription: String? {
        "A newer audio-session request replaced this one."
    }
}

public extension ManagedAudioSession {
    func activate() async throws {
        let generation = beginLifecycleIntent(wantsActive: true)
        await acquireLifecycleTransition()
        defer { releaseLifecycleTransition() }

        do {
            try validateLifecycleIntent(generation, wantsActive: true)
            await loadPreferenceIfNeeded()
            try validateLifecycleIntent(generation, wantsActive: true)
            try await backend.configure(allowsBluetoothHFP: preferences.allowsBluetoothHFP)
            try validateLifecycleIntent(generation, wantsActive: true)
            try await backend.setActive(true)
            sessionActive = true
            try validateLifecycleIntent(generation, wantsActive: true)
            try await selectPreferredInput()
            try validateLifecycleIntent(generation, wantsActive: true)
            let diagnostics = await backend.diagnostics(isActive: true)
            try validateLifecycleIntent(generation, wantsActive: true)
            recordDiagnostics(diagnostics)
            startBackendEventsIfNeeded()
        } catch {
            await recoverFromActivationFailure(generation: generation)
            throw normalizedLifecycleError(error, generation: generation)
        }
    }

    func deactivate() async {
        let generation = beginLifecycleIntent(wantsActive: false)
        await acquireLifecycleTransition()
        defer { releaseLifecycleTransition() }

        guard generation == lifecycleGeneration, !wantsActive else { return }
        sessionActive = false
        try? await backend.setActive(false)
        let diagnostics = await backend.diagnostics(isActive: false)
        guard generation == lifecycleGeneration, !wantsActive else { return }
        recordDiagnostics(diagnostics)
    }

    func retryInputSelection() async throws {
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
        inputSelectionGeneration &+= 1
        let generation = inputSelectionGeneration
        let lifecycle = lifecycleGeneration
        activeInputSelectionGeneration = generation
        defer {
            if activeInputSelectionGeneration == generation {
                activeInputSelectionGeneration = nil
            }
        }
        await loadPreferenceIfNeeded()
        let inputs = await backend.availableInputs().filter(isSelectable)
        try validateRetry(generation, lifecycle: lifecycle)
        guard let input = inputs.first(where: { $0.id == savedPreferredInput?.id })
            ?? preferences.resolve(from: inputs) else {
            throw AudioInputSelectionError.noSelectableInput
        }
        do {
            try await backend.selectInput(id: input.id)
            try validateRetry(generation, lifecycle: lifecycle)
            let diagnostics = await backend.diagnostics(isActive: true)
            try validateRetry(generation, lifecycle: lifecycle)
            guard diagnostics.input?.id == input.id else {
                throw AudioInputSelectionError.routeMismatch(expected: input, actual: diagnostics.input)
            }
            failedInputAttempt = nil
            inputFailureDescription = nil
            publish(diagnostics)
        } catch {
            if error as? AudioInputSelectionError == .superseded { throw error }
            await recordInputFailure(attempted: input, error: error, generation: generation)
            throw error
        }
    }
}

extension ManagedAudioSession {
    func recordInputFailure(attempted: AudioPort?, error: any Error, generation: Int) async {
        let lifecycle = lifecycleGeneration
        let revision = diagnosticsRevision
        let snapshot = await backend.diagnostics(isActive: sessionActive)
        guard generation == inputSelectionGeneration,
              lifecycle == lifecycleGeneration,
              wantsActive,
              sessionActive else { return }
        let diagnostics = revision == diagnosticsRevision ? snapshot : latestDiagnostics
        failedInputAttempt = attempted
        inputFailureDescription = error.localizedDescription
        diagnosticsRevision &+= 1
        recordDiagnostics(diagnostics)
        eventBroadcast.yield(.routeChanged(diagnostics))
    }

    func repairPersistedPreference() async {
        let previous = preferenceSaveTail
        let store = preferenceStore
        let preference = savedPreferredInput
        let repair = Task {
            await previous?.value
            await store.save(preference)
        }
        preferenceSaveTail = repair
        await repair.value
    }
}

private extension ManagedAudioSession {
    func validateRetry(_ generation: Int, lifecycle: UInt64) throws {
        guard generation == inputSelectionGeneration,
              lifecycle == lifecycleGeneration,
              wantsActive,
              sessionActive else {
            throw AudioInputSelectionError.superseded
        }
    }

    func beginLifecycleIntent(wantsActive: Bool) -> UInt64 {
        lifecycleGeneration &+= 1
        self.wantsActive = wantsActive
        guard !wantsActive else { return lifecycleGeneration }
        inputSelectionGeneration &+= 1
        activeInputSelectionGeneration = nil
        pendingPreferredInput = nil
        routeReconciliationNeeded = false
        return lifecycleGeneration
    }

    func validateLifecycleIntent(_ generation: UInt64, wantsActive: Bool) throws {
        guard generation == lifecycleGeneration, self.wantsActive == wantsActive else {
            throw AudioSessionLifecycleError.superseded
        }
    }

    func normalizedLifecycleError(_ error: any Error, generation: UInt64) -> any Error {
        guard generation == lifecycleGeneration else { return AudioSessionLifecycleError.superseded }
        return error
    }

    func recoverFromActivationFailure(generation: UInt64) async {
        if generation == lifecycleGeneration {
            wantsActive = false
        }
        guard !wantsActive else { return }
        sessionActive = false
        try? await backend.setActive(false)
        recordDiagnostics(await backend.diagnostics(isActive: false))
    }

    func acquireLifecycleTransition() async {
        if !lifecycleTransitionLocked {
            lifecycleTransitionLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleTransitionWaiters.append(continuation)
        }
    }

    func releaseLifecycleTransition() {
        guard !lifecycleTransitionWaiters.isEmpty else {
            lifecycleTransitionLocked = false
            return
        }
        lifecycleTransitionWaiters.removeFirst().resume()
    }
}
