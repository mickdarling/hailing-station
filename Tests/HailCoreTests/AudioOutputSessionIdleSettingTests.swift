import Testing
@testable import HailCore

struct AudioOutputSessionIdleSettingTests {
    @Test(arguments: [false, true])
    func idleHFPSettingSupersedesUnreflectedStandaloneBuiltInRequest(newerConfirmedFirst: Bool) async throws {
        let backend = TakeoverBackend(mic: .hfp, refusesHFP: false, defersSelection: true)
        let session = ManagedAudioSession(backend: backend, preferences: .init(),
                                          preferenceStore: VolatileAudioInputPreferenceStore())
        try await backend.configureStandalone(.init(allowsBluetoothHFP: false))
        let initial = await backend.selections
        #expect(initial == [AudioPort.builtIn.id])
        try await session.setAllowsBluetoothHFP(true)
        let afterSetting = await backend.selections
        #expect(afterSetting == [AudioPort.builtIn.id, AudioPort.hfp.id])
        if newerConfirmedFirst { await backend.confirmPreferred() }
        await backend.confirm(.builtIn)
        await backend.confirm(.builtIn)
        await backend.confirmPreferred()
        let final = await backend.selections
        let pair = await backend.actualPair
        let expected = newerConfirmedFirst ? afterSetting + [AudioPort.hfp.id] : afterSetting
        #expect(final == expected)
        #expect(pair?.inputs == [.bluetoothHFP])
        #expect(pair?.outputs == [.bluetoothHFP])
    }

    @Test func idleToggleSelectsAlreadyConnectedAirPodsWithOnlyCategoryNotice() async throws {
        let backend = TakeoverBackend(mic: .builtIn, refusesHFP: false)
        let session = ManagedAudioSession(backend: backend, preferences: .init(),
                                          preferenceStore: VolatileAudioInputPreferenceStore())
        try await session.setAllowsBluetoothHFP(true)
        let selections = await backend.selections
        let mic = await backend.mic
        #expect(selections == [AudioPort.hfp.id])
        #expect(mic == .hfp)
    }

    @Test func captureTakeoverUsesSavedMicWhenHFPWouldBeRefused() async throws {
        let backend = TakeoverBackend()
        let store = VolatileAudioInputPreferenceStore()
        await store.save(.builtIn)
        let session = ManagedAudioSession(backend: backend, preferences: .init(), preferenceStore: store)
        await #expect(throws: FakeAudioError.self) { try await session.setAllowsBluetoothHFP(true) }
        let idleCalls = await backend.idleConfigurations
        #expect(idleCalls == 1)
        try await session.activate()
        let diagnostics = await session.diagnostics
        #expect(diagnostics.isActive)
        #expect(diagnostics.input == .builtIn)
        let selections = await backend.selections
        #expect(selections == [AudioPort.hfp.id, AudioPort.builtIn.id])
        await session.deactivate()
    }
}

private actor TakeoverBackend: AudioSessionBackend, AudioSessionIdleConfiguring {
    var idleConfigurations = 0
    let driver = AudioOutputRouteDriver()
    var selections: [AudioPort.ID] = []
    static let systemInput = AudioPort(id: "system-mic", name: "System input", kind: .other)
    var mic: AudioPort
    let refusesHFP: Bool
    let defersSelection: Bool
    var actualPair: AudioOutputRoutePolicy.Pair? { driver.lastObservation?.actual.pair }

    init(mic: AudioPort = TakeoverBackend.systemInput, refusesHFP: Bool = true, defersSelection: Bool = false) {
        self.mic = mic
        self.refusesHFP = refusesHFP
        self.defersSelection = defersSelection
        driver.ownership = .init(owner: .standalone, isActive: true)
    }

    func configureIfStationOwned(allowsBluetoothHFP: Bool) async throws {
        idleConfigurations += 1
        try AudioSessionIdleOwnership.configureIfStationOwned(
            category: AudioSessionIdleOwnership.playAndRecordCategory, options: 0, allowsHFP: allowsBluetoothHFP
        ) { try configure($1, allowsHFP: $0) }
    }

    func configure(allowsBluetoothHFP: Bool) async throws {
        try configure(.capturePreparation, allowsHFP: allowsBluetoothHFP)
    }

    private func configure(_ source: AudioOutputSessionOwnership.Request, allowsHFP: Bool) throws {
        try driver.ownership.configure(source, allowsHFP: allowsHFP, category: { owner, allows in
            self.driver.ownership.configured(for: owner, continuing: true, allowsHFP: allows)
        }, standalone: configureStandalone)
    }

    private var route: AudioOutputRoutePolicy.Route {
        .init(owner: .standalone, outputs: mic == .hfp ? [.bluetoothHFP] : [.bluetoothA2DP],
              inputs: mic == .hfp ? [.bluetoothHFP] : [.builtInMic], availableInputs: [.builtInMic, .bluetoothHFP],
              reason: .categoryChange, awaitingInputSelection: driver.ownership.awaitingInputSelection)
    }

    private func inputs() -> (available: [AudioPort], currentID: AudioPort.ID?) { ([.builtIn, .hfp], mic.id) }

    func configureStandalone(_ preferences: AudioInputPreferences) throws {
        try driver.configureStandalone(preferences: preferences, prepare: {
            driver.ownership.configured(for: .standalone, continuing: true, allowsHFP: preferences.allowsBluetoothHFP)
            deliver(route)
        }, inputs: inputs, select: select, reconcile: {})
    }

    func confirmPreferred() {
        guard let requested = selections.last, let port = [AudioPort.hfp, .builtIn].first(where: { $0.id == requested })
        else {
            Issue.record("Expected a preferred-input request")
            return
        }
        confirm(port)
    }

    func confirm(_ selected: AudioPort) {
        let before = route
        mic = selected
        var notice = route
        notice.reason = .routeConfigurationChange
        notice.previousInputs = before.inputs
        notice.previousOutputs = before.outputs
        deliver(notice)
    }

    private func deliver(_ notice: AudioOutputRoutePolicy.Route) {
        driver.routeChanged(notice, actual: { self.route }, perform: { _ in Issue.record("Unexpected output write") },
                            inputs: inputs, select: select)
    }

    func setActive(_ active: Bool) async throws {
        driver.ownership.configured(for: .capture, continuing: false, allowsHFP: true)
        driver.ownership.isActive = active
    }

    func availableInputs() async -> [AudioPort] { [.hfp, .builtIn, Self.systemInput] }

    func selectInput(id: AudioPort.ID?) async throws {
        guard let port = [AudioPort.builtIn, .hfp].first(where: { $0.id == id }) else {
            throw FakeAudioError.selectionFailed
        }
        try select(port)
    }

    private func select(_ port: AudioPort) throws {
        let type = port == .hfp ? AudioOutputRoutePolicy.Port.bluetoothHFP : .builtInMic
        try driver.write(.preferredInput(type), before: route, actual: { self.route }, perform: {
            selections.append(port.id)
            if port == .hfp, refusesHFP { throw FakeAudioError.selectionFailed }
            if !defersSelection { mic = port }
        })
    }

    func diagnostics(isActive: Bool) async -> AudioSessionDiagnostics {
        .init(isActive: isActive, input: mic, outputs: [], sampleRate: 48_000)
    }

    func eventStream() async -> AsyncStream<AudioSessionBackendEvent> {
        AsyncStream { $0.finish() }
    }
}
