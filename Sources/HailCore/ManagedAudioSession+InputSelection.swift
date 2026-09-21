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
        let request = try await beginSelection(id: id)
        do {
            try await backend.selectInput(id: request.port.id)
            let diagnostics = try await verifiedDiagnostics(for: request)
            savedPreferredInput = request.preference
            await preferenceStore.save(request.preference)
            try validateSelection(request.generation)
            pendingPreferredInput = nil
            let final = try await reconcileRouteIfNeeded(generation: request.generation) ?? diagnostics
            publish(final)
        } catch {
            await recoverFromFailedSelection(request.generation)
            throw error
        }
    }
}

extension ManagedAudioSession {
    func selectPreferredInput() async throws {
        await loadPreferenceIfNeeded()
        let inputs = await backend.availableInputs()
        let input = inputs.first { $0.id == savedPreferredInput?.id && isSelectable($0) }
            ?? preferences.resolve(from: inputs)
        let current = await backend.diagnostics(isActive: sessionActive).input
        guard input?.id != current?.id else { return }
        try await backend.selectInput(id: input?.id)
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

    func beginSelection(id: AudioPort.ID?) async throws -> InputSelectionRequest {
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
        inputSelectionGeneration &+= 1
        let generation = inputSelectionGeneration
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

    func verifiedDiagnostics(for request: InputSelectionRequest) async throws -> AudioSessionDiagnostics {
        try validateSelection(request.generation)
        let diagnostics = await backend.diagnostics(isActive: true)
        try validateSelection(request.generation)
        guard diagnostics.input?.id == request.port.id else {
            latestDiagnostics = diagnostics
            throw AudioInputSelectionError.routeMismatch(expected: request.port, actual: diagnostics.input)
        }
        return diagnostics
    }

    func validateSelection(_ generation: Int) throws {
        guard generation == inputSelectionGeneration else {
            throw AudioInputSelectionError.superseded
        }
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
    }

    func reconcileRouteIfNeeded(generation: Int) async throws -> AudioSessionDiagnostics? {
        guard routeReconciliationNeeded else { return nil }
        routeReconciliationNeeded = false
        if wantsActive { try? await selectPreferredInput() }
        try validateSelection(generation)
        let diagnostics = await backend.diagnostics(isActive: sessionActive)
        try validateSelection(generation)
        return diagnostics
    }

    func recoverFromFailedSelection(_ generation: Int) async {
        guard generation == inputSelectionGeneration else { return }
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
