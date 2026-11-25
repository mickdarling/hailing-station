#if os(macOS)
import SwiftUI
import Testing
@testable import HailCore

extension StationBackgroundCaptureTests {
    enum ChangeDuringCleanup: CaseIterable, Sendable { case activateScene, startAmbient, both }

    @Test(arguments: ChangeDuringCleanup.allCases)
    func sceneReleaseRechecksAfterTalkDrains(_ change: ChangeDuringCleanup) async throws {
        let scene = try await BackgroundCaptureScene()
        defer { scene.host.finish() }
        let root = try #require(scene.probe.root)
        var mountedSession: StationTalkSession?
        scene.probe.talkSurface = AnyView(SceneTalkProbe { mountedSession = $0 })
        await scene.host.render()
        let session = try #require(mountedSession)
        try await root.audioRoutes.activate()
        let owner = UUID(), entered = OpenGate(), drain = OpenGate()
        let admitted = session.admit(owner, receive: { _ in }, cleanup: {
            await entered.release()
            await drain.wait()
            session.retire(owner)
        })
        try #require(admitted)
        scene.host.setScenePhase(.inactive)
        await scene.host.render()
        await entered.wait()
        if change != .startAmbient {
            scene.host.setScenePhase(.active)
            await scene.host.render()
        }
        if change != .activateScene {
            await scene.rig.controller.turnOn(for: scene.binding)
            #expect(scene.rig.store.ambientStreaming)
        }
        let before = await scene.backend.activationHistory
        await drain.release()
        // Admission reopens only after the root's release callback has returned.
        let next = UUID()
        try await waitUntil { await session.admit(next, receive: { _ in }, cleanup: {}) }
        #expect(await scene.backend.activationHistory == before)
        #expect(root.audioRoutes.diagnostics.isActive)
        session.retire(next)
        await scene.rig.close()
    }
}

private struct SceneTalkProbe: View {
    @StationTranscriptionView.WindowTalk private var session
    let onMount: @MainActor (StationTalkSession) -> Void

    init(onMount: @escaping @MainActor (StationTalkSession) -> Void) { self.onMount = onMount }

    var body: some View { Color.clear.onAppear { onMount(session) } }
}
#endif
