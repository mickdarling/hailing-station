public actor ManagedAudioSession: AudioSessionDiagnosticsProviding {
    private let backend: any AudioSessionBackend
    private let preferences: AudioInputPreferences
    private let preferenceStore: any AudioInputPreferenceStoring
    private let eventPair = AsyncStream<AudioSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    private var backendTask: Task<Void, Never>?
    private var latestDiagnostics = AudioSessionDiagnostics.inactive
    private var savedPreferredInput: AudioPort?
    private var pendingPreferredInput: AudioPort?
    private var loadedPreference = false
    private var inputSelectionGeneration = 0
    private var wantsActive = false
    private var sessionActive = false

    public init(
        backend: any AudioSessionBackend,
        preferences: AudioInputPreferences = AudioInputPreferences(),
        preferenceStore: any AudioInputPreferenceStoring = UserDefaultsAudioInputPreferenceStore()
    ) {
        self.backend = backend
        self.preferences = preferences
        self.preferenceStore = preferenceStore
    }

    deinit {
        backendTask?.cancel()
        eventPair.continuation.finish()
    }

    public var diagnostics: AudioSessionDiagnostics {
        latestDiagnostics
    }

    public var events: AsyncStream<AudioSessionEvent> {
        eventPair.stream
    }

    public var availableInputs: [AudioPort] {
        get async {
            await backend.availableInputs().filter(isSelectable)
        }
    }

    public var preferredInput: AudioPort? {
        get async {
            await loadPreferenceIfNeeded()
            return pendingPreferredInput ?? savedPreferredInput
        }
    }

    public func activate() async throws {
        wantsActive = true
        do {
            await loadPreferenceIfNeeded()
            try await backend.configure(allowsBluetoothHFP: preferences.allowsBluetoothHFP)
            try await backend.setActive(true)
            sessionActive = true
            try await selectPreferredInput()
            latestDiagnostics = await backend.diagnostics(isActive: true)
            startBackendEventsIfNeeded()
        } catch {
            wantsActive = false
            sessionActive = false
            try? await backend.setActive(false)
            latestDiagnostics = await backend.diagnostics(isActive: false)
            throw error
        }
    }

    public func deactivate() async {
        wantsActive = false
        sessionActive = false
        inputSelectionGeneration &+= 1
        pendingPreferredInput = nil
        do {
            try await backend.setActive(false)
        } catch {
            // Deactivation is best-effort because this protocol is also used from teardown paths.
        }
        latestDiagnostics = await backend.diagnostics(isActive: false)
    }

    public func selectInput(id: AudioPort.ID) async throws {
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
        let inputs = await backend.availableInputs().filter(isSelectable)
        guard let selected = inputs.first(where: { $0.id == id }) else {
            throw AudioInputSelectionError.unavailable(id)
        }

        inputSelectionGeneration &+= 1
        let generation = inputSelectionGeneration
        pendingPreferredInput = selected
        do {
            try await backend.selectInput(id: selected.id)
            try validateSelection(generation)
            let diagnostics = await backend.diagnostics(isActive: true)
            try validateSelection(generation)
            guard diagnostics.input?.id == selected.id else {
                latestDiagnostics = diagnostics
                throw AudioInputSelectionError.routeMismatch(expected: selected, actual: diagnostics.input)
            }

            savedPreferredInput = selected
            await preferenceStore.save(selected)
            try validateSelection(generation)
            pendingPreferredInput = nil
            latestDiagnostics = diagnostics
            eventPair.continuation.yield(.routeChanged(diagnostics))
        } catch {
            if generation == inputSelectionGeneration {
                pendingPreferredInput = nil
            }
            throw error
        }
    }

    func handle(_ event: AudioSessionBackendEvent) async {
        switch event {
        case .routeChanged:
            await handleRouteChange()
        case .interruptionBegan:
            sessionActive = false
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventPair.continuation.yield(.interruptionBegan)
        case .interruptionEnded(let shouldResume):
            await handleInterruptionEnd(shouldResume: shouldResume)
        }
    }
}

private extension ManagedAudioSession {
    private func startBackendEventsIfNeeded() {
        guard backendTask == nil else { return }
        let backend = backend
        backendTask = Task { [weak self] in
            let stream = await backend.eventStream()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func selectPreferredInput() async throws {
        await loadPreferenceIfNeeded()
        let inputs = await backend.availableInputs()
        let input = inputs.first { $0.id == savedPreferredInput?.id && isSelectable($0) }
            ?? preferences.resolve(from: inputs)
        let current = await backend.diagnostics(isActive: sessionActive).input
        guard input?.id != current?.id else { return }
        try await backend.selectInput(id: input?.id)
    }

    private func loadPreferenceIfNeeded() async {
        guard !loadedPreference else { return }
        savedPreferredInput = await preferenceStore.load()
        loadedPreference = true
    }

    private func isSelectable(_ port: AudioPort) -> Bool {
        port.kind != .bluetoothHFP || preferences.allowsBluetoothHFP
    }

    private func validateSelection(_ generation: Int) throws {
        guard generation == inputSelectionGeneration else {
            throw AudioInputSelectionError.superseded
        }
        guard sessionActive else { throw AudioInputSelectionError.sessionInactive }
    }

    private func handleRouteChange() async {
        if wantsActive, pendingPreferredInput == nil {
            try? await selectPreferredInput()
        }
        latestDiagnostics = await backend.diagnostics(isActive: sessionActive)
        eventPair.continuation.yield(.routeChanged(latestDiagnostics))
    }

    private func handleInterruptionEnd(shouldResume: Bool) async {
        guard wantsActive, shouldResume else {
            sessionActive = false
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventPair.continuation.yield(.interruptionEnded(resumed: false))
            return
        }
        do {
            try await backend.setActive(true)
            sessionActive = true
            try await selectPreferredInput()
            latestDiagnostics = await backend.diagnostics(isActive: true)
            eventPair.continuation.yield(.interruptionEnded(resumed: true))
        } catch {
            sessionActive = false
            try? await backend.setActive(false)
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventPair.continuation.yield(.interruptionEnded(resumed: false))
        }
    }
}
