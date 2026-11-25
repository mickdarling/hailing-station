#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import HailCore
@testable import StationTalkTestSupport

@MainActor
struct MountedStationDock {
    let scene: BackgroundCaptureScene
    let tap: FakeAudioCapture
    let speech: FakeTranscriber
    let probe: MountedTalkProbe
    let view: StationTalkTestSupport.StationTranscriptionView
    let destination: DestinationControlState
    let escapes: TalkCallCounter

    init(scene: BackgroundCaptureScene, ambientStreaming: Bool) async throws {
        self.scene = scene
        let root = try #require(scene.probe.root)
        let playback = root.playback
        playback.captureLivenessSleep = { _ in throw CancellationError() }
        if ambientStreaming {
            try await root.audioRoutes.activate()
            await scene.rig.controller.turnOn(for: scene.binding)
        }
        try #require(scene.rig.store.ambientStreaming == ambientStreaming)
        let tap = FakeAudioCapture(), speech = FakeTranscriber(), probe = MountedTalkProbe()
        (self.tap, self.speech, self.probe) = (tap, speech, probe)
        let escapes = TalkCallCounter()
        self.escapes = escapes
        let session = StationTalkTestSupport.StationTalkSession {
            StationTalkTestSupport.TranscriptionResources(capture: tap, transcriber: speech)
        }
        let id = TalkDestinationID(endpointID: scene.binding.hostID, targetID: scene.binding.targetID)
        let route = StationTalkTestSupport.StationTalkRoute(store: scene.rig.store, selected: { id },
            reportRemoval: { _ in Issue.record("Unexpected destination removal") })
        let station = StationTalkTestSupport.StationTranscriptionView(audioSession: root.audioRoutes,
            destinationID: id, route: route,
            onCaptureWillBegin: { CapturePlaybackSuppression.begin($0, using: playback) },
            onCaptureDidEnd: { CapturePlaybackSuppression.end($0, using: playback, resuming: $1) },
            onCaptureTeardownCompleted: { CapturePlaybackSuppression.markCleanupComplete($0, using: playback) },
            onFinalized: { _, _ in Issue.record("Unexpected standalone delivery") }, onEscape: { escapes.value += 1 })
        let destination = DestinationControlState.confirmed(DestinationLabel(
            hostName: "Fixture", targetName: "Session", targetKind: "tmux", targetID: id.targetID))
        self.destination = destination
        let controls = StationTalkTestSupport.StationDockControls(destination: { destination },
            privacy: nil, listening: {}, routes: {})
        let flags = StationRedesignFlags { $0 == StationRedesignStep.shell.key ? true : nil }
        let surface = flags.isOn(.shell) ? station.renderingDock(controls) : station
        scene.host.window.fixtureOcclusion = .visible
        scene.probe.talkSurface = AnyView(surface.sharingTalkSession(session).environment(probe))
        await scene.host.render()
        view = try #require(probe.view)
        try #require(view.dock != nil && probe.buttonIsEnabled && view.selectedBinding != nil)
    }

    func dispatch(_ intent: VoiceDockIntent) -> Task<Void, Never>? {
        view.dispatchDockPrimary(intent, destination: destination,
            accessories: DockAccessories(escape: true, privacy: true, paste: false, privacyEnabled: false))
    }

    func occlusion(_ state: NSWindow.OcclusionState) {
        scene.host.window.fixtureOcclusion = state
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: scene.host.window)
    }

    func expectRefused() async {
        let previous = tap.startCount
        let attempted = dispatch(.talk)
        #expect(attempted == nil && view.startTask == nil)
        await attempted?.value
        #expect(tap.startCount == previous && !view.isRecording && view.talkSession.owner == nil)
    }

    func expectStartAndFinish() async throws {
        try #require(probe.buttonIsEnabled)
        let previous = tap.startCount
        let press = try #require(probe.press)
        press() // The real VoiceDockView button sends its intent to dispatchDockPrimary.
        let start = try #require(view.startTask)
        await start.value
        try #require(view.isRecording && tap.startCount == previous + 1 && view.recordingDestination != nil)
        let finish = try #require(dispatch(.finish))
        await finish.value
        #expect(view.startTask == nil && view.finishTask == nil && !view.isRecording && view.talkSession.owner == nil)
        #expect(await !speech.isRunning)
    }
}

@MainActor
func withMountedStationDock(ambientStreaming: Bool = true,
                            _ run: (MountedStationDock) async throws -> Void) async throws {
    let scene = try await BackgroundCaptureScene()
    defer { scene.host.finish() }
    do {
        let dock = try await MountedStationDock(scene: scene, ambientStreaming: ambientStreaming)
        do {
            try await run(dock)
        } catch {
            await dock.view.finish(force: true)
            throw error
        }
        await dock.view.finish(force: true)
    } catch {
        await scene.rig.close()
        throw error
    }
    await scene.rig.close()
}
#endif
