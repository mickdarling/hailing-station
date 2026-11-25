#if os(macOS)
import SwiftUI
import Testing
@testable import HailCore
@testable import StationTalkTestSupport

extension StationBackgroundCaptureTests {
    enum RouteUser: CaseIterable, Sendable { case none, otherTalk, ambient, reply }

    @Test(arguments: RouteUser.allCases)
    func leavingFinishedLabsDeactivatesOnlyAnUnusedRoute(_ user: RouteUser) async throws {
        try await expectDeparture(user, stationLeaves: false)
    }

    @Test(arguments: RouteUser.allCases)
    func losingFinishedStationDestinationDeactivatesOnlyAnUnusedRoute(_ user: RouteUser) async throws {
        try await expectDeparture(user, stationLeaves: true)
    }

    @Test func hidingAQueuedLabsStartPreservesStationRecording() async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let root = try #require(scene.probe.root)
        let surfaces = TalkDepartureSurfaces(root: root, stationLeaves: false)
        scene.host.window.fixtureOcclusion = .visible
        scene.probe.talkSurface = surfaces.showingBoth(true)
        await scene.host.render()
        let labs = try #require(surfaces.leaving.view)
        let station = try #require(surfaces.staying.view)
        let tap = try #require(station.capture as? FakeAudioCapture)
        let speech = try #require(station.transcriber as? FakeTranscriber)
        let admitLabs = OpenGate()
        let queued = Task {
            await admitLabs.wait()
            await labs.begin(whenVisible: { true })
        }
        labs.startTask = queued
        await station.begin(whenVisible: { true })
        labs.stopCaptureWhenHidden()
        let hide = labs.finishTask
        await admitLabs.release()
        await hide?.value
        await queued.value
        #expect(hide != nil && queued.isCancelled && labs.startTask == nil && labs.finishTask == nil)
        #expect(station.isRecording && surfaces.session.owner == station.captureOwnerID)
        #expect(tap.startCount == 1 && tap.stopCount == 0)
        #expect(await speech.isRunning)
        await station.finish()
        await scene.rig.close()
    }

    private func expectDeparture(_ user: RouteUser, stationLeaves: Bool) async throws {
        let scene = try await BackgroundCaptureScene(supportsText: true)
        defer { scene.host.finish() }
        let root = try #require(scene.probe.root)
        let surfaces = TalkDepartureSurfaces(root: root, stationLeaves: stationLeaves)
        scene.host.window.fixtureOcclusion = .visible
        scene.probe.talkSurface = surfaces.showingBoth(true)
        await scene.host.render()
        let staying = try #require(surfaces.staying.view)
        try await surfaces.finishLeavingTalk(socket: scene.rig.socket)

        switch user {
        case .none: break
        case .otherTalk:
            await staying.begin(whenVisible: { true })
            try #require(staying.isRecording && surfaces.session.owner == staying.captureOwnerID)
        case .ambient:
            try await root.audioRoutes.activate()
            await scene.rig.controller.turnOn(for: scene.binding)
            try #require(scene.rig.store.ambientStreaming)
        case .reply:
            root.playback.ingest(duplexEvent())
            try #require(root.playback.isReplyAudioOutputBusy)
        }
        let before = await scene.backend.activationHistory
        scene.probe.talkSurface = surfaces.showingBoth(false)
        await scene.host.render()
        #expect(surfaces.departures.value == 1)
        if user == .none { try await waitUntil { await scene.backend.activationHistory.last == false } }
        #expect(await scene.backend.activationHistory == (user == .none ? before + [false] : before))
        if user == .otherTalk {
            #expect(staying.isRecording && staying.talkSession.owner == staying.captureOwnerID)
            await staying.finish()
        }
        if user == .ambient { try await scene.expectAmbientContinues(root: root) }
        await scene.rig.close()
    }
}

@MainActor
private struct TalkDepartureSurfaces {
    let root: StationRootView
    let stationLeaves: Bool
    let leaving = MountedTalkProbe(), staying = MountedTalkProbe()
    let departures = TalkCallCounter()
    let session = StationTalkTestSupport.StationTalkSession {
        StationTalkTestSupport.TranscriptionResources(capture: FakeAudioCapture(), transcriber: FakeTranscriber())
    }

    func showingBoth(_ shown: Bool) -> AnyView {
        AnyView(VStack {
            talk(station: !stationLeaves).environment(staying)
            if shown { talk(station: stationLeaves).environment(leaving).onDisappear { departures.value += 1 } }
        }.sharingTalkSession(session))
    }

    func finishLeavingTalk(socket: ScriptedSocket) async throws {
        let view = try #require(leaving.view)
        let speech = try #require(view.transcriber as? FakeTranscriber)
        try #require((view.onFinalized != nil) == stationLeaves)
        try #require((view.destinationID != nil) == stationLeaves)
        await view.begin(whenVisible: { true })
        try #require(view.isRecording && session.owner == view.captureOwnerID)
        try #require(view.recordingDestination?.destination == view.destinationID)
        await speech.emit(TranscriptionResult(text: "fixture request", isFinal: true))
        await view.finish()
        let sends = TalkCallCounter()
        sends.value = try await socket.sentFrames().count { frame in
            if case .text = frame.payload { true } else { false }
        }
        try #require(sends.value == (stationLeaves ? 1 : 0))
        try #require(!view.isRecording && session.owner == nil && root.audioRoutes.diagnostics.isActive)
    }

    private var destinationID: TalkDestinationID? {
        root.destination.map { TalkDestinationID(endpointID: $0.hostID, targetID: $0.target.id) }
    }

    private func talk(station: Bool) -> some View {
        let send: @MainActor (String, PastedDraft?) async throws -> Void = { _, _ in
            Issue.record("Station transcript bypassed its recorded destination")
        }
        return StationTalkTestSupport.StationTranscriptionView(audioSession: root.audioRoutes,
            destinationID: station ? destinationID : nil,
            route: station ? StationTalkTestSupport.StationTalkRoute(
                store: root.connections, selected: { destinationID }, reportRemoval: { _ in }) : nil,
            globalReplyAudioSpeaking: root.playback.isReplyAudioOutputBusy,
            onCaptureWillBegin: { CapturePlaybackSuppression.begin($0, using: root.playback) },
            onCaptureDidEnd: { CapturePlaybackSuppression.end($0, using: root.playback, resuming: $1) },
            onFinalized: station ? send : nil)
    }
}
#endif
