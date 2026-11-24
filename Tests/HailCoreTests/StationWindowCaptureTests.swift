#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StationWindowCaptureTests {
    @Test func disposedWindowNeverLeavesTheMicrophoneRunningUnseenDuringASend() async throws {
        let fixture = try WindowCaptureFixture()
        do {
            try await fixture.closeWindowDuringAudioSend()
            try await fixture.checkWindowlessCapture()
        } catch {
            await fixture.cleanUp()
            throw error
        }
        await fixture.cleanUp()
    }
}

/// The test retains the capture probe, menu and scripted peer. Only production code can keep the station alive.
@MainActor
private final class WindowCaptureFixture {
    private let menu = StationMenuStatus()
    private let capture = FakeAudioCapture()
    private let gate = HeldSocketSend()
    private let socket = ScriptedSocket()
    private let host: HostEndpoint
    private weak var connections: HostConnectionStore?

    init() throws { host = try endpoint() }

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

    func closeWindowDuringAudioSend() async throws {
        let (store, binding) = try await connect()
        store.ambientController = AmbientListeningController(
            notificationCenter: NotificationCenter(), requestPermission: { true },
            makeStreamer: { [capture] send in AmbientAudioStreamer(capture: capture, send: send) },
            releaseSession: {}, send: { [weak store] audio, binding in
                guard let store else { throw HostConnectionFailure.notReady }
                try await store.sendAudio(audio, to: binding)
            })
        let probe = NativeSceneAmbientProbe(binding: binding)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let resources = StationResources(connections: store, backend: FakeAudioSessionBackend(inputs: []),
            player: FormatTestPlayer(), keepaliveRenderer: FakeKeepaliveRenderer(),
            diagnostics: DeviceDiagnostics(defaults: defaults, appInfo: [:]))
        let window = NativeSceneAmbientHost(resources: resources, probe: probe, menuStatus: menu)
        do {
            await window.render()
            try await waitForAudioTestState { await self.menu.canToggleListening }
            try #require(probe.root?.ambientDestinationBinding == binding)
            menu.setListening(true)
            try await waitForAudioTestState { await self.menu.listening == .listening }
            try #require(capture.isRunning)
            try capture.yield(sineBuffer(frames: 14_400))
            try await waitForAudioTestState { await self.gate.started.released }
        } catch {
            window.finish()
            throw error
        }
        probe.root = nil
        await window.dispose()
        try #require(probe.disappearances > 0 && !menu.windowOpen)
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
        await gate.completion.release()
        await store?.ambientController?.turnOff()
        await store?.disconnect(host.id)
        await socket.close()
    }
}
#endif
