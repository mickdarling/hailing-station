public actor ManagedAudioSession: AudioSessionDiagnosticsProviding {
    let backend: any AudioSessionBackend
    let preferences: AudioInputPreferences
    let preferenceStore: any AudioInputPreferenceStoring
    let eventBroadcast = AudioSessionEventBroadcast()
    private var backendTask: Task<Void, Never>?
    var latestDiagnostics = AudioSessionDiagnostics.inactive
    var savedPreferredInput: AudioPort?
    var pendingPreferredInput: AudioPort?
    var loadedPreference = false
    var inputSelectionGeneration = 0
    var activeInputSelectionGeneration: Int?
    var preferenceSaveTail: Task<Void, Never>?
    var latestQueuedPreferenceGeneration = 0
    var routeReconciliationNeeded = false
    var diagnosticsRevision = 0
    var wantsActive = false
    var sessionActive = false
    var lifecycleGeneration: UInt64 = 0
    var lifecycleTransitionLocked = false
    var lifecycleTransitionWaiters: [CheckedContinuation<Void, Never>] = []

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
        eventBroadcast.finish()
    }

    public var diagnostics: AudioSessionDiagnostics {
        latestDiagnostics
    }

    public var events: AsyncStream<AudioSessionEvent> {
        eventBroadcast.stream()
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
            eventBroadcast.yield(.interruptionBegan)
        case .interruptionEnded(let shouldResume):
            await handleInterruptionEnd(shouldResume: shouldResume)
        }
    }
}

extension ManagedAudioSession {
    func publish(_ diagnostics: AudioSessionDiagnostics) {
        diagnosticsRevision &+= 1
        latestDiagnostics = diagnostics
        eventBroadcast.yield(.routeChanged(diagnostics))
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

    func startBackendEventsIfNeeded() {
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

    @discardableResult
    func reconcileRouteWhenIdle() async -> Bool {
        var reconciled = false
        while routeReconciliationNeeded, activeInputSelectionGeneration == nil, wantsActive, sessionActive {
            routeReconciliationNeeded = false
            let generation = inputSelectionGeneration
            do {
                try await selectPreferredInput(expectedGeneration: generation)
                reconciled = true
            } catch AudioInputSelectionError.superseded {
                routeReconciliationNeeded = true
            } catch {
                return reconciled
            }
        }
        return reconciled
    }
}

private extension ManagedAudioSession {
    private func handleRouteChange() async {
        if wantsActive {
            routeReconciliationNeeded = true
            await reconcileRouteWhenIdle()
        }
        let generation = inputSelectionGeneration
        let revision = diagnosticsRevision
        let diagnostics = await backend.diagnostics(isActive: sessionActive)
        guard generation == inputSelectionGeneration,
              revision == diagnosticsRevision else { return }
        publish(diagnostics)
    }

    private func handleInterruptionEnd(shouldResume: Bool) async {
        guard wantsActive, shouldResume else {
            sessionActive = false
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventBroadcast.yield(.interruptionEnded(resumed: false))
            return
        }
        do {
            try await backend.setActive(true)
            sessionActive = true
            try await selectPreferredInput()
            latestDiagnostics = await backend.diagnostics(isActive: true)
            eventBroadcast.yield(.interruptionEnded(resumed: true))
        } catch {
            sessionActive = false
            try? await backend.setActive(false)
            latestDiagnostics = await backend.diagnostics(isActive: false)
            eventBroadcast.yield(.interruptionEnded(resumed: false))
        }
    }
}
