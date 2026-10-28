import SwiftUI
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AudioDiagnosticsLifetimeTests {
    @Test func idleActivationThenBackReleasesTheToolsSession() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let model = AudioRouteModel(controller: ManagedAudioSession(backend: backend))
        let session = AudioDiagnosticsSession()
        let store = HostConnectionStore()
        let host = NativeStationToolHost(
            AudioDiagnosticsView(model: model, session: session).environment(store), isTool: true)
        defer { host.finish() }
        try await host.appeared()
        session.activate(model)
        await session.activation?.value
        #expect(model.diagnostics.isActive)
        host.pop() // Back from the real diagnostics view.
        try await waitUntil { await MainActor.run { session.disappearance != nil } }
        await session.disappearance?.value
        #expect(!model.diagnostics.isActive)
        #expect(await backend.activationHistory == [true, false])
    }

    @Test(arguments: [false, true])
    func captureOwnsSessionWhenDiagnosticsDisappears(toolActivatedFirst: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let model = AudioRouteModel(controller: ManagedAudioSession(backend: backend))
        let session = AudioDiagnosticsSession()
        if toolActivatedFirst {
            session.activate(model)
            await session.activation?.value
        } else { try await model.activate() }
        let host = NativeStationToolHost(
            AudioDiagnosticsView(model: model, session: session).environment(rig.store), isTool: true)
        defer { host.finish() }
        try await host.appeared()
        host.pop()
        try await waitUntil { await MainActor.run { session.disappearance != nil } }
        await session.disappearance?.value
        #expect(model.diagnostics.isActive && rig.controller.isListening && rig.released == 0)
        #expect(await backend.activationHistory == [true])
        await rig.close()
        await model.deactivate()
    }

    @Test func pendingToolActivationIsJoinedBeforeCleanup() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let model = AudioRouteModel(controller: ManagedAudioSession(backend: backend))
        let session = AudioDiagnosticsSession()
        session.activate(model)
        session.disappear(model, captureOwnsSession: { false })
        await session.disappearance?.value
        #expect(!model.diagnostics.isActive)
        #expect(await backend.activationHistory == [true, false])
    }
}
