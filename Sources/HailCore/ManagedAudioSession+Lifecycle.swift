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
            latestDiagnostics = diagnostics
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
        latestDiagnostics = diagnostics
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
        latestDiagnostics = await backend.diagnostics(isActive: false)
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
