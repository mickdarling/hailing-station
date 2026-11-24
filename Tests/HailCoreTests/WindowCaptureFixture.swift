#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// After dismantling, only production code can keep the station alive during the held send.
@MainActor
final class WindowCaptureFixture {
    let menu: StationMenuStatus
    let capture = FakeAudioCapture()
    private let gate = HeldSocketSend()
    private let released = CompletionFlag()
    private let socket = ScriptedSocket()
    private let host: HostEndpoint
    private(set) weak var connections: HostConnectionStore?
    private(set) weak var controller: AmbientListeningController?
    private(set) var window: NativeSceneAmbientHost?

    init(menu: StationMenuStatus) throws {
        self.menu = menu
        host = try endpoint()
    }

    private var menuOffersStop: Bool {
        menu.listening == .listening && menu.canToggleListening
            && menu.summary.localizedCaseInsensitiveContains("listening")
    }

    func checkWindowlessCapture() async throws {
        // Allow teardown work queued by the released SwiftUI owner to run. The audio write stays held throughout.
        do {
            try await waitForAudioTestState { await MainActor.run { !self.capture.isRunning || self.menuOffersStop } }
        } catch AudioLifecycleAdmissionTestError.watchdogExpired {
            // Report the observed capture and menu state at the invariant below.
        }
        try #require(!capture.isRunning || menuOffersStop,
                     "Microphone still running. Menu: \(menu.summary), toggle enabled: \(menu.canToggleListening)")
        if capture.isRunning {
            menu.setListening(false)
            try await waitForAudioTestState { await !self.capture.isRunning }
        }
    }

    func open() async throws {
        let (store, binding) = try await connect()
        store.ambientController = AmbientListeningController(
            notificationCenter: NotificationCenter(), requestPermission: { true },
            makeStreamer: { [capture] send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: { [released] in await released.set() }, send: { [weak store] audio, binding in
                guard let store else { throw HostConnectionFailure.notReady }
                try await store.sendAudio(audio, to: binding)
            })
        let probe = NativeSceneAmbientProbe(binding: binding)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let resources = StationResources(connections: store, backend: FakeAudioSessionBackend(inputs: []),
            player: FormatTestPlayer(), keepaliveRenderer: FakeKeepaliveRenderer(),
            diagnostics: DeviceDiagnostics(defaults: defaults, appInfo: [:]))
        let window = NativeSceneAmbientHost(resources: resources, probe: probe, menuStatus: menu)
        controller = store.ambientController
        self.window = window
        await window.render()
        try await waitForAudioTestState { await self.menu.canToggleListening }
        try #require(window.resourceFactoryCalls == 1 && probe.root?.ambientDestinationBinding == binding)
    }

    func holdAudioSend() async throws {
        menu.setListening(true)
        try await waitForAudioTestState { await self.menu.listening == .listening }
        try #require(capture.isRunning)
        try capture.yield(sineBuffer(frames: 14_400))
        try await waitForAudioTestState { await self.gate.started.released }
    }

    func closeWindow() { window?.finish() }

    func dismantle() async throws {
        await window?.dismantle()
        try #require((window?.probe.disappearances ?? 0) > 0)
        window = nil
    }

    func drain() async throws {
        await gate.completion.release()
        try await waitForAudioTestState { await self.released.isSet }
        let final = try #require(try await audioFrames(socket).last)
        if case .audio(let audio) = final.payload { #expect(audio.isFinal) }
    }

    private func connect() async throws -> (HostConnectionStore, AmbientAudioBinding) {
        let target = CardsArrivalRig.target
        try await socket.push(.hello(HelloInfo(versions: VersionNegotiation.supported,
            capabilities: ["ping", "select_target", "stream_audio"], deviceName: "Synthetic")))
        try await socket.push(.targets([target]))
        let connector = ScriptedConnector()
        await connector.enqueue(.socket(AnsweringSocket(base: socket, audioError: nil, gate: gate)), for: host.url)
        let store = HostConnectionStore(connector: connector, deadlineSleep: { _ in throw CancellationError() })
        connections = store
        await store.upsert(host)
        await store.connect(host.id)
        try await waitForAudioTestState { await store.snapshots[self.host.id]?.receivedTargetList == true }
        try await store.selectTarget(host: host.id, targetID: target.id)
        return try (store, #require(store.ambientBinding(host: host.id, targetID: target.id)))
    }

    func cleanUp() async {
        let store = connections
        capture.stop() // Finish the fixture's input independently of production teardown.
        await gate.completion.release()
        await store?.ambientController?.turnOff()
        closeWindow()
        await window?.dismantle()
        await store?.disconnect(host.id)
        await socket.close()
    }
}
#endif
