public extension ManagedAudioSession {
    var availableInputs: [AudioPort] {
        get async {
            await backend.availableInputs().filter(isSelectable)
        }
    }

    var preferredInput: AudioPort? {
        get async {
            await loadPreferenceIfNeeded()
            return pendingPreferredInput ?? savedPreferredInput
        }
    }

    func selectInput(id: AudioPort.ID?) async throws {
        let generation = try startSelection()
        do {
            let request = try await resolveSelection(id: id, generation: generation)
            try await backend.selectInput(id: request.port.id)
            let diagnostics = try await verifiedDiagnostics(for: request)
            try await persistPreference(for: request)
            pendingPreferredInput = nil
            let final = try await reconcileRouteIfNeeded(generation: request.generation) ?? diagnostics
            try verify(final, matches: request)
            publish(final)
            await finishSelection(generation)
        } catch {
            await recoverFromFailedSelection(generation)
            await finishSelection(generation)
            throw error
        }
    }
}

extension ManagedAudioSession {
    func selectPreferredInput(expectedGeneration: Int? = nil) async throws {
        await loadPreferenceIfNeeded()
        let inputs = await backend.availableInputs()
        try validateRouteApplication(expectedGeneration)
        let input = inputs.first { $0.id == savedPreferredInput?.id && isSelectable($0) }
            ?? preferences.resolve(from: inputs)
        let current = await backend.diagnostics(isActive: sessionActive).input
        try validateRouteApplication(expectedGeneration)
        guard input?.id != current?.id else { return }
        try await backend.selectInput(id: input?.id)
        try validateRouteApplication(expectedGeneration)
    }

    func loadPreferenceIfNeeded() async {
        guard !loadedPreference else { return }
        savedPreferredInput = await preferenceStore.load()
        loadedPreference = true
    }

    func isSelectable(_ port: AudioPort) -> Bool {
        port.kind != .bluetoothHFP || preferences.allowsBluetoothHFP
    }
}

private extension ManagedAudioSession {
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

    func finishSelection(_ generation: Int) async {
        if activeInputSelectionGeneration == generation {
            activeInputSelectionGeneration = nil
        }
        guard await reconcileRouteWhenIdle() else { return }
        let diagnosticGeneration = inputSelectionGeneration
        let diagnostics = await backend.diagnostics(isActive: sessionActive)
        guard diagnosticGeneration == inputSelectionGeneration,
              activeInputSelectionGeneration == nil else { return }
        publish(diagnostics)
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

    func verifiedDiagnostics(for request: InputSelectionRequest) async throws -> AudioSessionDiagnostics {
        try validateSelection(request.generation)
        let diagnostics = await backend.diagnostics(isActive: true)
        try validateSelection(request.generation)
        try verify(diagnostics, matches: request)
        return diagnostics
    }

    func verify(_ diagnostics: AudioSessionDiagnostics, matches request: InputSelectionRequest) throws {
        guard diagnostics.input?.id == request.port.id else {
            latestDiagnostics = diagnostics
            throw AudioInputSelectionError.routeMismatch(expected: request.port, actual: diagnostics.input)
        }
    }

    func validateSelection(_ generation: Int) throws {
        guard generation == inputSelectionGeneration else {
            throw AudioInputSelectionError.superseded
        }
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
    }

    func validateRouteApplication(_ generation: Int?) throws {
        guard let generation else { return }
        guard generation == inputSelectionGeneration,
              activeInputSelectionGeneration == nil,
              wantsActive,
              sessionActive else {
            throw AudioInputSelectionError.superseded
        }
    }

    func reconcileRouteIfNeeded(generation: Int) async throws -> AudioSessionDiagnostics? {
        guard routeReconciliationNeeded else { return nil }
        repeat {
            routeReconciliationNeeded = false
            if wantsActive { try? await selectPreferredInput() }
            try validateSelection(generation)
        } while routeReconciliationNeeded
        let diagnostics = await backend.diagnostics(isActive: sessionActive)
        try validateSelection(generation)
        return diagnostics
    }

    func recoverFromFailedSelection(_ generation: Int) async {
        guard generation == inputSelectionGeneration else {
            routeReconciliationNeeded = true
            await reconcileRouteWhenIdle()
            return
        }
        pendingPreferredInput = nil
        if let diagnostics = try? await reconcileRouteIfNeeded(generation: generation) {
            publish(diagnostics)
        }
    }

    func publish(_ diagnostics: AudioSessionDiagnostics) {
        latestDiagnostics = diagnostics
        eventPair.continuation.yield(.routeChanged(diagnostics))
    }
}
