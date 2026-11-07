#if os(macOS)
import Foundation
import HailProtocol
@testable import HailDaemonKit

/// PR 2a fixtures stay separate from the existing meeting/privacy rigs and their unchanged gate wiring.
func preboundAmbientRig(
    _ fake: FakeRightyo, timing: RightyoChildProcess.Timing,
    acknowledgements: AmbientAckLibrary? = nil,
    destinations: VoiceDestinations? = nil, routes: VoiceRoutes? = nil
) async throws -> AmbientWiringRig {
    let rig = try await RecipientTestRig.make(), connected = ConnectedPeerIDs()
    var configuration = AmbientRightyoRouter.Configuration(
        executable: fake.executable, config: fake.config, target: "recipient:other", binding: "other-binding",
        allowSynthetic: true, timing: timing, acknowledgements: acknowledgements, replyControl: true
    )
    configuration.destinations = destinations
    let router = AmbientRightyoRouter(configuration: configuration)
    let sink = PreboundAmbientSink(base: GuardClockAmbientSink(router: router))
    let gate = AmbientAudioGate(target: RecipientTestRig.target, sink: sink, sweepInterval: nil)
    let listener = try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: rig.host,
        authorizer: PersonalTerminalAuthorizer(ambientAudio: gate).naming(routes), hostName: "mac-test",
        singleTerminalReplyFallback: true, ambient: router, log: { connected.record($0) }
    )
    return AmbientWiringRig(rig: rig, listener: listener, router: router, gate: gate, connected: connected,
                            port: try await boundedAmbientListenerStart(listener))
}

/// Inject only the authored binding at STARTED; all other fixture behavior uses the original sink unchanged.
private struct PreboundAmbientSink: AmbientAudioSink {
    let base: GuardClockAmbientSink
    func ambientAudio(_ event: AmbientAudioEvent) {
        if case .started(let stream, let connection, let scope) = event {
            base.ambientAudio(.started(stream: stream, connection: connection, target: scope.target,
                                       selection: scope.selection, binding: "reply-binding"))
        } else { base.ambientAudio(event) }
    }
    func ambientInputRoute(_ route: String, connection: UUID) { base.ambientInputRoute(route, connection: connection) }
    func ambientPrivacy(_ on: Bool, connection: UUID) { base.ambientPrivacy(on, connection: connection) }
    func ambientPrivacyPreArm(connection: UUID) { base.ambientPrivacyPreArm(connection: connection) }
    func ambientPrivacyPreArmRefused(connection: UUID, reason: String) {
        base.ambientPrivacyPreArmRefused(connection: connection, reason: reason)
    }
}
#endif
