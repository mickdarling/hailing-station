public actor ManagedAudioSession: AudioSessionDiagnosticsProviding {
    let backend: any AudioSessionBackend
    let preferences: AudioInputPreferences
    let preferenceStore: any AudioInputPreferenceStoring
    let eventPair = AsyncStream<AudioSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    private var backendTask: Task<Void, Never>?
    var latestDiagnostics = AudioSessionDiagnostics.inactive
    var savedPreferredInput: AudioPort?
    var pendingPreferredInput: AudioPort?
    var loadedPreference = false
    var inputSelectionGeneration = 0
    var activeInputSelectionGeneration: Int?
    var preferenceSaveTail: Task<Void, Never>?
    var routeReconciliationNeeded = false
    var wantsActive = false
    var sessionActive = false

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
        activeInputSelectionGeneration = nil
        pendingPreferredInput = nil
        routeReconciliationNeeded = false
        do {
            try await backend.setActive(false)
        } catch {
            // Deactivation is best-effort because this protocol is also used from teardown paths.
        }
        latestDiagnostics = await backend.diagnostics(isActive: false)
    }

    func handle(_ event: AudioSessionBackendEvent) async {
        switch event {
        case .routeChanged:
            await handleRouteChange()
        case .interruptionBegan:
            sessionActive = false
            inputSelectionGeneration &+= 1
            activeInputSelectionGeneration = nil
            pendingPreferredInput = nil
            routeReconciliationNeeded = false
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

    private func handleRouteChange() async {
        if wantsActive {
            routeReconciliationNeeded = true
            await reconcileRouteWhenIdle()
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
