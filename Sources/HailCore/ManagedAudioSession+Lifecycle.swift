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
        let generation = try startSelection()
        let lifecycle = lifecycleGeneration
        var attemptedInput: AudioPort?
        do {
            await loadPreferenceIfNeeded()
            let inputs = await backend.availableInputs().filter(isSelectable)
            try validateRetry(generation, lifecycle: lifecycle)
            guard let input = inputs.first(where: { $0.id == savedPreferredInput?.id })
                ?? preferences.resolve(from: inputs) else {
                throw AudioInputSelectionError.noSelectableInput
            }
            attemptedInput = input
            try await backend.selectInput(id: input.id)
            try validateRetry(generation, lifecycle: lifecycle)
            let diagnostics = await backend.diagnostics(isActive: true)
            try validateRetry(generation, lifecycle: lifecycle)
            if diagnostics.input?.id != input.id { routeReconciliationNeeded = true }
            try await finishSelection(generation, expectedPort: nil)
            let confirmed = try await confirmedRetryDiagnostics(generation: generation, lifecycle: lifecycle)
            failedInputAttempt = nil
            inputFailureDescription = nil
            publish(confirmed)
        } catch {
            do {
                try validateRetry(generation, lifecycle: lifecycle)
            } catch {
                try? await finishSelection(generation, expectedPort: nil)
                throw error
            }
            let failedInput = failedInput(for: error, fallback: attemptedInput)
            stageInputFailure(attempted: failedInput, error: error)
            await recoverFromFailedSelection(generation)
            if await finishFailedSelection(generation) {
                await recordInputFailure(attempted: failedInput, error: error, generation: generation)
            }
            throw error
        }
    }
}
extension ManagedAudioSession {
    func validateRetry(_ generation: Int, lifecycle: UInt64) throws {
        guard generation == inputSelectionGeneration,
              lifecycle == lifecycleGeneration,
              wantsActive,
              sessionActive else {
            throw AudioInputSelectionError.superseded
        }
    }
    func reconcileRouteIfNeeded(generation: Int) async throws -> AudioSessionDiagnostics? {
        guard routeReconciliationNeeded else { return nil }
        repeat {
            routeReconciliationNeeded = false
            do {
                if wantsActive { try await selectPreferredInput(expectedGeneration: generation) }
            } catch {
                try validateSelection(generation)
                throw error
            }
            try validateSelection(generation)
        } while routeReconciliationNeeded
        let diagnostics = await backend.diagnostics(isActive: sessionActive)
        try validateSelection(generation)
        return diagnostics
    }
    func failedInput(for error: any Error, fallback: AudioPort?) -> AudioPort? {
        guard case .routeMismatch(let expected, _) = error as? AudioInputSelectionError else { return fallback }
        return expected
    }
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
