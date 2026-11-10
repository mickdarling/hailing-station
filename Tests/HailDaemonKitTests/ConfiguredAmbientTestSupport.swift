#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

private struct ConfiguredRecordingSink: AmbientAudioSink {
    let recording: RecordingAmbientSink
    let router: AmbientRightyoRouter
    func ambientAudio(_ event: AmbientAudioEvent) {
        recording.ambientAudio(event)
        router.ambientAudio(event)
    }
}

/// Authored child output and loopback peers; no microphone, tmux, provider or playback.
struct ConfiguredAmbientRig {
    static let target = VoiceRouteRig.scratch
    let base: VoiceRouteRig
    let fake: FakeRightyo
    let router: AmbientRightyoRouter
    let gate: AmbientAudioGate
    let session: HostSession
    let connection: UUID
    let pair: FallbackSocketPair
    let listener: WebSocketListener
    let sink: RecordingAmbientSink
    let events: AmbientEventDetails

    static func make(behavior: String = ambientEchoAtEOF, fixture: String = "tool-events.jsonl",
                     routes: VoiceRoutes? = nil, capabilities: [String] = ["probe"],
                     acknowledgementHold: AcknowledgementHold? = nil,
                     routerTarget: String = target) async throws -> Self {
        let base = try await VoiceRouteRig.make()
        let fake = try FakeRightyo(behavior)
        try fake.install(fixture: fixture)
        let events = AmbientEventDetails()
        var configuration = AmbientRightyoRouter.Configuration(
            executable: fake.executable, config: fake.config, target: routerTarget, binding: "startup-hint",
            allowSynthetic: true, timing: .init(eofGrace: 0.5, termGrace: 0.1)
        )
        if let acknowledgementHold {
            configuration.acknowledgements = AmbientAckLibrary(clips: ["default": [PendingInputRun.ack]])
            configuration.acknowledgementHold = acknowledgementHold.wait
        }
        let router = AmbientRightyoRouter(configuration: configuration, log: { events.record($0) })
        let sink = RecordingAmbientSink()
        let gate = AmbientAudioGate(target: target, sink: ConfiguredRecordingSink(recording: sink, router: router),
                                    sweepInterval: nil)
        let authorizer = PersonalTerminalAuthorizer(ambientAudio: gate).naming(routes)
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: base.host,
                                            authorizer: authorizer, hostName: "mac-test", ambient: router)
        router.attach(listener)
        let port = try await boundedAmbientListenerStart(listener)
        let pair = try await FallbackSocketPair.boundedConnect(port: port, selecting: [target],
                                                                   capabilities: capabilities)
        let session = try #require(await listener.peers.values.first?.session)
        return Self(base: base, fake: fake, router: router, gate: gate, session: session,
                    connection: await session.connectionID, pair: pair, listener: listener, sink: sink, events: events)
    }

    func segment(_ stream: UUID, _ sequence: Int = 0, final: Bool = false) async -> HostSessionResult {
        await session.receive(sessionFrame(target: Self.target,
            payload: .audio(ambientSegment(stream: stream, sequence: sequence, isFinal: final))))
    }

    func rebind(_ binding: String = "replacement", allow: Bool = false) async throws {
        await base.adapter.setTargets([AdapterTarget(name: "scratch", binding: binding)])
        if allow { _ = try await base.host.allow(Self.target, tier: .open) }
    }

    func scope() throws -> AmbientStreamScope {
        try #require(sink.events.compactMap { event in
            if case .started(_, _, let scope) = event { return scope }
            return nil
        }.last)
    }

    func dispatcher(_ scope: AmbientStreamScope) -> AmbientListenerDispatcher {
        AmbientListenerDispatcher(listener: listener, audit: nil, selection: scope.selection,
                                  streamTarget: scope.target, binding: scope.binding,
                                  policyGeneration: scope.policyGeneration)
    }

    func request(_ scope: AmbientStreamScope) -> LocalDispatchRequest {
        LocalDispatchRequest(connection: connection, target: scope.target, binding: scope.binding ?? "",
                             text: "synthetic request")
    }

    func cleanUp() async {
        pair.close()
        await listener.stop()
        await router.shutdown()
        await base.listener.stop()
        fake.cleanUp()
    }
}
#endif
