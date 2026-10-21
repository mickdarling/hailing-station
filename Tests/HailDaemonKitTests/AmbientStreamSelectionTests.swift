#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// An ambient stream keeps the selection generation it opened on (#636, second-key review on #691): the session hands
/// it to the gate with the stream's first segment, and every request the stream's consumer dispatches is delivered
/// only while the session is still on it. Selecting away, even and back, leaves an old stream nothing to deliver.
/// Synthetic only: a fake tmux-kind adapter, never-started transports.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientStreamSelectionTests {
    static func request(_ connection: UUID) -> LocalDispatchRequest {
        LocalDispatchRequest(connection: connection, target: VoiceRouteRig.scratch, binding: "s",
                             text: "synthetic input" + RightyoInputEvent.replyBlock(target: VoiceRouteRig.scratch))
    }

    static func select(_ target: String, on session: HostSession) async {
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
    }

    static func audio(_ stream: UUID) -> Frame {
        sessionFrame(target: VoiceRouteRig.scratch, payload: .audio(ambientSegment(stream: stream, sequence: 0)))
    }

    @Test func aStreamOpensOnTheSessionsSelectionGeneration() async throws {
        let rig = try await VoiceRouteRig.make()
        let sink = RecordingAmbientSink()
        let gate = ambientGate(target: VoiceRouteRig.scratch, sink: sink, clock: AmbientTestClock())
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate),
                                  hostName: "mac-test")
        _ = await session.receive(helloFrame())
        await Self.select(VoiceRouteRig.scratch, on: session)
        let (connection, first, second) = (await session.connectionID, UUID(), UUID())
        let opened = await session.selectionGeneration
        #expect(await session.receive(Self.audio(first)).frames.isEmpty)
        await Self.select(VoiceRouteRig.other, on: session)
        await Self.select(VoiceRouteRig.scratch, on: session)
        let reopened = await session.selectionGeneration
        #expect(await session.receive(Self.audio(second)).frames.isEmpty)
        let starts = sink.events.filter { if case .started = $0 { true } else { false } }
        #expect(starts == [.started(stream: first, connection: connection, selection: opened),
                           .started(stream: second, connection: connection, selection: reopened)])
        #expect(opened != reopened)
    }

    /// The stream's consumer dispatches after the owner went away and back: refused, nothing typed anywhere.
    @Test(arguments: [false, true])
    func aRequestFromAStreamOpenedBeforeAReselectionIsRefused(_ awayOnly: Bool) async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session()
        await rig.listener.installFallbackSyntheticPeers([session])
        let connection = await session.connectionID
        let stream = AmbientListenerDispatcher(listener: rig.listener, audit: nil,
                                               selection: await session.selectionGeneration)
        await Self.select(VoiceRouteRig.other, on: session)
        if !awayOnly { await Self.select(VoiceRouteRig.scratch, on: session) }
        let refusal: LocalDispatchRefusal = awayOnly ? .targetNotSelected : .selectionChanged
        await #expect(throws: refusal) { try await stream.dispatch(Self.request(connection)) }
        #expect(await rig.adapter.deliveries.isEmpty)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// While the selection the stream opened on holds, its request is delivered, as before.
    @Test func aRequestFromAStreamOnTheCurrentSelectionIsDelivered() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session()
        await rig.listener.installFallbackSyntheticPeers([session])
        let stream = AmbientListenerDispatcher(listener: rig.listener, audit: nil,
                                               selection: await session.selectionGeneration)
        // Selecting the selected target again is not a reselection: the generation stands.
        await Self.select(VoiceRouteRig.scratch, on: session)
        _ = try await stream.dispatch(Self.request(await session.connectionID))
        #expect(await rig.adapter.deliveries.map(\.target) == ["scratch"])
        await rig.listener.stop(reason: "synthetic test complete")
    }
}
#endif
