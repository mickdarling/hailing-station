import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AudioDiagnosticsPermissionTests {
    @Test(arguments: [false, true])
    func backCancelsPendingCaptureAndReleasesToolActivationBeforePermissionResolves(granted: Bool) async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let model = AudioRouteModel(controller: ManagedAudioSession(backend: backend))
        let session = AudioDiagnosticsSession()
        session.activate(model)
        await session.activation?.value
        let permission = DiagnosticsPermissionGate()
        let capture = FakeAudioCapture()
        let controller = AmbientListeningController(requestPermission: {
            await permission.request()
        }, makeStreamer: { send in
            try await model.activate()
            return AmbientAudioStreamer(capture: capture, send: send)
        }, releaseSession: { await model.deactivate() }, send: { _, _ in })
        let store = HostConnectionStore()
        store.ambientController = controller
        let host = NativeStationToolHost(
            AudioDiagnosticsView(model: model, session: session).environment(store), isTool: true)
        defer { host.finish() }
        await host.render()
        let destination = try binding()
        let start = Task { await controller.turnOn(for: destination) }
        await permission.waitUntilRequested()
        #expect(controller.isOn && !controller.isListening && model.diagnostics.isActive)
        host.pop()
        await host.render()
        let disappearance = try #require(session.disappearance)
        await disappearance.value
        #expect(!controller.isOn && !controller.isListening && !model.diagnostics.isActive)
        await permission.resolve(granted)
        await start.value
        #expect(!controller.isOn && !controller.isListening && !model.diagnostics.isActive)
        #expect(capture.startCount == 0)
        #expect(await backend.activationHistory == [true, false])
        await controller.turnOff()
        await model.deactivate()
    }

    @Test func backTransfersToolActivationToLiveCaptureUntilCaptureStops() async throws {
        let backend = FakeAudioSessionBackend(inputs: [.builtIn])
        let model = AudioRouteModel(controller: ManagedAudioSession(backend: backend))
        let session = AudioDiagnosticsSession()
        session.activate(model)
        await session.activation?.value
        let capture = FakeAudioCapture()
        let controller = AmbientListeningController(requestPermission: { true }, makeStreamer: { send in
            try await model.activate()
            return AmbientAudioStreamer(capture: capture, send: send)
        }, releaseSession: { await model.deactivate() }, send: { _, _ in })
        let store = HostConnectionStore()
        store.ambientController = controller
        let host = NativeStationToolHost(
            AudioDiagnosticsView(model: model, session: session).environment(store), isTool: true)
        defer { host.finish() }
        await host.render()
        await controller.turnOn(for: try binding())
        host.pop()
        await host.render()
        let disappearance = try #require(session.disappearance)
        await disappearance.value
        #expect(controller.isOn && controller.isListening && model.diagnostics.isActive)
        #expect(capture.startCount == 1)
        #expect(await backend.activationHistory == [true, true])
        await controller.turnOff()
        #expect(!model.diagnostics.isActive)
        #expect(await backend.activationHistory == [true, true, false])
    }
}

/// Permission resolves only when the test supplies the owner's answer.
private actor DiagnosticsPermissionGate {
    private let requested = AsyncStream<Void>.makeStream()
    private var permission: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            permission = continuation
            requested.continuation.yield(())
        }
    }

    func waitUntilRequested() async {
        for await _ in requested.stream { return }
    }

    func resolve(_ granted: Bool) {
        permission?.resume(returning: granted)
        permission = nil
    }
}
