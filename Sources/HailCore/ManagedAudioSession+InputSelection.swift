public extension ManagedAudioSession {
    var availableInputs: [AudioPort] { get async { await backend.availableInputs().filter(isSelectable) } }
    var preferredInput: AudioPort? {
        get async {
            await loadPreferenceIfNeeded()
            return pendingPreferredInput ?? savedPreferredInput
        }
    }
    func selectInput(id: AudioPort.ID?) async throws {
        let generation = try startSelection()
        var attemptedInput: AudioPort?
        do {
            let request = try await resolveSelection(id: id, generation: generation)
            attemptedInput = request.port
            try await backend.selectInput(id: request.port.id)
            let diagnostics = try await verifiedDiagnostics(for: request)
            try await persistPreference(for: request)
            pendingPreferredInput = nil
            let final = try await reconcileRouteIfNeeded(generation: request.generation) ?? diagnostics
            if request.preference != nil { try verify(final, matches: request) }
            failedInputAttempt = nil
            inputFailureDescription = nil
            publish(final)
            try await finishSelection(generation, expectedPort: request.preference)
        } catch {
            let shouldRecord = generation == inputSelectionGeneration
                && error as? AudioInputSelectionError != .superseded
            let failedInput = failedInput(for: error, fallback: attemptedInput)
            if shouldRecord { stageInputFailure(attempted: failedInput, error: error) }
            await recoverFromFailedSelection(generation)
            let cleanupSucceeded = await finishFailedSelection(generation)
            if shouldRecord, cleanupSucceeded {
                await recordInputFailure(attempted: failedInput, error: error, generation: generation)
            }
            throw error
        }
    }
}

extension ManagedAudioSession {
    @discardableResult
    func selectPreferredInput(expectedGeneration: Int? = nil) async throws -> AudioSessionDiagnostics {
        await loadPreferenceIfNeeded()
        let inputs = await backend.availableInputs()
        try validateRouteApplication(expectedGeneration)
        let input = inputs.first { $0.id == savedPreferredInput?.id && isSelectable($0) }
            ?? preferences.resolve(from: inputs)
        guard let input else { throw AudioInputSelectionError.noSelectableInput }
        let currentDiagnostics = await backend.diagnostics(isActive: sessionActive)
        let current = currentDiagnostics.input
        try validateRouteApplication(expectedGeneration)
        guard input.id != current?.id else {
            failedInputAttempt = nil
            inputFailureDescription = nil
            return currentDiagnostics
        }
        do {
            try await backend.selectInput(id: input.id)
        } catch {
            guard expectedGeneration != nil else { throw error }
            try validateRouteApplication(expectedGeneration)
            throw AudioInputSelectionError.routeMismatch(expected: input, actual: current)
        }
        try validateRouteApplication(expectedGeneration)
        let diagnostics = await backend.diagnostics(isActive: sessionActive)
        try validateRouteApplication(expectedGeneration)
        guard diagnostics.input?.id == input.id else {
            throw AudioInputSelectionError.routeMismatch(expected: input, actual: diagnostics.input) }
        failedInputAttempt = nil
        inputFailureDescription = nil
        return diagnostics
    }
    func loadPreferenceIfNeeded() async {
        guard !loadedPreference else { return }
        savedPreferredInput = await preferenceStore.load()
        loadedPreference = true
    }
    func isSelectable(_ port: AudioPort) -> Bool { port.kind != .bluetoothHFP || preferences.allowsBluetoothHFP }
}
extension ManagedAudioSession {
    struct InputSelectionRequest {
        let generation: Int
        let port: AudioPort
        let preference: AudioPort?
    }
    func startSelection() throws -> Int {
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
        inputSelectionGeneration &+= 1
        let generation = inputSelectionGeneration
        activeInputSelectionGeneration = generation
        pendingPreferredInput = nil
        return generation
    }
    func resolveSelection(id: AudioPort.ID?, generation: Int) async throws -> InputSelectionRequest {
        let inputs = await backend.availableInputs().filter(isSelectable)
        try validateSelection(generation)
        if let id {
            guard let port = inputs.first(where: { $0.id == id }) else {
                throw AudioInputSelectionError.unavailable(id)
            }
            pendingPreferredInput = port
            return InputSelectionRequest(generation: generation, port: port, preference: port)
        }
        guard let port = preferences.resolve(from: inputs) else {
            throw AudioInputSelectionError.noSelectableInput
        }
        pendingPreferredInput = port
        return InputSelectionRequest(generation: generation, port: port, preference: nil)
    }
    func finishSelection(_ generation: Int, expectedPort: AudioPort?) async throws {
        if activeInputSelectionGeneration == generation {
            activeInputSelectionGeneration = nil
        }
        let reconciled = try await reconcileRouteWhenIdle()
        try validateSelection(generation)
        guard reconciled else { return }
        let revision = diagnosticsRevision
        let snapshot = await backend.diagnostics(isActive: sessionActive)
        try validateSelection(generation)
        let diagnostics: AudioSessionDiagnostics
        if revision == diagnosticsRevision {
            diagnostics = snapshot
            publish(snapshot)
        } else {
            diagnostics = latestDiagnostics
        }
        guard let expectedPort, diagnostics.input?.id != expectedPort.id else { return }
        throw AudioInputSelectionError.routeMismatch(expected: expectedPort, actual: diagnostics.input)
    }
    func persistPreference(for request: InputSelectionRequest) async throws {
        let previous = preferenceSaveTail
        let store = preferenceStore
        latestQueuedPreferenceGeneration = request.generation
        let save = Task {
            await previous?.value
            await store.save(request.preference)
        }
        preferenceSaveTail = save
        await save.value
        do {
            try validateSelection(request.generation)
        } catch {
            if latestQueuedPreferenceGeneration == request.generation {
                await repairPersistedPreference()
            }
            throw error
        }
        savedPreferredInput = request.preference
    }
    func verifiedDiagnostics(for request: InputSelectionRequest) async throws -> AudioSessionDiagnostics {
        try validateSelection(request.generation)
        let diagnostics = await backend.diagnostics(isActive: true)
        try validateSelection(request.generation)
        try verify(diagnostics, matches: request)
        return diagnostics
    }
    func verify(_ diagnostics: AudioSessionDiagnostics, matches request: InputSelectionRequest) throws {
        guard diagnostics.input?.id == request.port.id else {
            recordDiagnostics(diagnostics)
            throw AudioInputSelectionError.routeMismatch(expected: request.port, actual: diagnostics.input)
        }
    }
    func validateSelection(_ generation: Int) throws {
        guard generation == inputSelectionGeneration else {
            throw AudioInputSelectionError.superseded
        }
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
    }
    func recoverFromFailedSelection(_ generation: Int) async {
        guard generation == inputSelectionGeneration else {
            routeReconciliationNeeded = true
            _ = try? await reconcileRouteWhenIdle()
            return
        }
        pendingPreferredInput = nil
        let stagedFailure = (failedInputAttempt, inputFailureDescription)
        if let diagnostics = try? await reconcileRouteIfNeeded(generation: generation) {
            failedInputAttempt = stagedFailure.0
            inputFailureDescription = stagedFailure.1
            publish(diagnostics)
            return
        }
        let diagnostics = await backend.diagnostics(isActive: sessionActive)
        guard generation == inputSelectionGeneration else { return }
        publish(diagnostics)
    }
    func confirmedRetryDiagnostics(generation: Int, lifecycle: UInt64) async throws -> AudioSessionDiagnostics {
        while true {
            let revision = diagnosticsRevision
            let diagnostics = try await selectPreferredInput(expectedGeneration: generation)
            try validateRetry(generation, lifecycle: lifecycle)
            if revision == diagnosticsRevision { return diagnostics }
        }
    }
    func finishFailedSelection(_ generation: Int) async -> Bool {
        do { try await finishSelection(generation, expectedPort: nil); return true } catch { return false }
    }
}
