#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct StationBackgroundCaptureTests {
    enum Departure: CaseIterable, Sendable { case sceneBackground, windowHidden, windowOccluded }

    @Test(arguments: NativeBackgroundTranscription.Surface.allCases, Departure.allCases)
    func stopsMountedCaptureWhileAmbientKeepsDelivering(
        _ surface: NativeBackgroundTranscription.Surface, _ departure: Departure
    ) async throws {
        let scene = try await BackgroundCaptureScene()
        let recording = NativeBackgroundTranscription(surface)
        defer { recording.tap.stop(); scene.host.finish() }
        scene.host.window.fixtureOcclusion = .visible
        scene.probe.transcription = recording
        await scene.host.render()
        let root = try #require(scene.probe.root)
        // The rig supplies ambient's streamer. Activate and release its shared route through the same native model.
        try await root.audioRoutes.activate()
        scene.rig.beforeSessionRelease = { await root.audioRoutes.deactivate() }
        await scene.rig.controller.turnOn(for: scene.binding)
        try #require(scene.rig.store.ambientStreaming && root.selectionAuthorizedForReadyConnection)
        try #require(root.authorizedConnectionGeneration == scene.binding.connectionGeneration)
        try await recording.start()
        let owner = try #require(recording.mounted?.captureOwnerID)
        let activations = await scene.backend.activationHistory
        let selections = await scene.backend.selectionCount
        try #require(activations.last == true && root.audioRoutes.diagnostics.input == .builtIn)

        try await depart(departure, scene: scene, recording: recording)
        let mounted = try #require(recording.mounted)
        await mounted.finishTask?.value
        #expect(mounted.captureOwnerID == owner && !mounted.isRecording && recording.tap.stopCount == 1)
        #expect(recording.disappearances == 0)
        #expect(await !recording.speech.isRunning)
        #expect(recording.sends == 0)
        try await scene.expectAmbientContinues(root: root)
        #expect(await scene.backend.activationHistory == activations)
        #expect(await scene.backend.selectionCount == selections)
        #expect(root.audioRoutes.diagnostics.isActive && root.audioRoutes.diagnostics.input == .builtIn)
        await scene.rig.close()
    }

    private func depart(_ departure: Departure, scene: BackgroundCaptureScene,
                        recording: NativeBackgroundTranscription) async throws {
        let root = try #require(scene.probe.root)
        switch departure {
        case .sceneBackground:
            scene.host.setScenePhase(.inactive)
            await scene.host.render()
            try #require(recording.tap.stopCount == 0)
            scene.host.setScenePhase(.background)
            await scene.host.render()
            try await waitUntil { await MainActor.run { !root.keepalive.sceneActive } }
        case .windowHidden, .windowOccluded:
            let other = TestHostWindow(size: NSSize(width: 100, height: 100))
            defer { other.close() }
            let name = NSWindow.didChangeOcclusionStateNotification
            NotificationCenter.default.post(name: name, object: other)
            NotificationCenter.default.post(name: name, object: scene.host.window) // Still visible.
            await scene.host.render()
            try #require(recording.tap.stopCount == 0 && scene.host.window.isVisible)
            if departure == .windowHidden {
                scene.host.window.orderOut(nil)
                try #require(!scene.host.window.isVisible)
            } else {
                scene.host.window.fixtureOcclusion = []
                try #require(scene.host.window.isVisible)
            }
            // Offscreen panels do not need a physical display transition to deliver the window's notification.
            NotificationCenter.default.post(name: name, object: scene.host.window)
            await scene.host.render()
            #expect(root.keepalive.sceneActive)
        }
    }

    @Test func backgroundWithoutAmbientFinishesTalkAndReleasesRouteAndAuthorization() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let root = try #require(scene.probe.root)
        let tap = FakeAudioCapture()
        let speech = FakeTranscriber()
        let talk = TranscriptionLabView(capture: tap, playback: root.playback, transcriber: speech)
        root.audioRoutes.installSceneCleanup { await talk.finish(force: true) }
        try await root.audioRoutes.activate()
        await talk.begin()
        try #require(talk.isRecording && tap.startCount == 1 && tap.stopCount == 0)
        try #require(!scene.rig.store.ambientStreaming && root.selectionAuthorizedForReadyConnection)
        try #require(root.authorizedConnectionGeneration == scene.binding.connectionGeneration)

        scene.host.setScenePhase(.background)
        await scene.host.render()
        try await waitUntil { await scene.backend.activationHistory.last == false }
        #expect(!talk.isRecording && tap.stopCount == 1)
        #expect(await !speech.isRunning)
        #expect(!root.selectionAuthorizedForReadyConnection && root.authorizedConnectionGeneration == nil)
        await scene.rig.close()
    }
}

@MainActor
private struct BackgroundCaptureScene {
    let rig: AmbientReconnectRig
    let binding: AmbientAudioBinding
    let probe: NativeSceneAmbientProbe
    let host: NativeSceneAmbientHost
    let backend = FakeAudioSessionBackend(inputs: [.builtIn])

    init() async throws {
        rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        binding = try rig.currentBinding()
        probe = NativeSceneAmbientProbe(binding: binding)
        host = NativeSceneAmbientHost(resources: StationResources(connections: rig.store, backend: backend,
            player: FormatTestPlayer(), keepaliveRenderer: FakeKeepaliveRenderer()), probe: probe)
        await host.render()
        try await waitUntil { [probe, binding, controller = rig.controller] in
            await MainActor.run {
                probe.root?.ambientDestinationBinding == binding && controller.onListeningChange != nil
            }
        }
    }

    func expectAmbientContinues(root: StationRootView) async throws {
        #expect(root.selectionAuthorizedForReadyConnection)
        #expect(root.authorizedConnectionGeneration == binding.connectionGeneration)
        #expect(root.ambientDestinationBinding == binding && rig.controller.binding == binding)
        #expect(rig.store.ambientStreaming && rig.controller.isListening)
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount == 0 && rig.released == 0)
        let before = try await audioFrames(rig.socket).count
        try await rig.feed()
        try await waitUntil { try await audioFrames(rig.socket).count > before }
    }
}
#endif
