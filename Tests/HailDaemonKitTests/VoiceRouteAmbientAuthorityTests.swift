#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The host side of ambient voice routing (#636, slice 4a): the listener's own ambient dispatch may address a route
/// the selection covers, and nothing else may. Synthetic only: a fake tmux-kind adapter, never-started transports.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRouteAmbientAuthorityTests {
    static func request(_ connection: UUID, to target: String, binding: String) -> LocalDispatchRequest {
        LocalDispatchRequest(connection: connection, target: target, binding: binding,
                             text: "synthetic input" + RightyoInputEvent.replyBlock(target: target))
    }

    /// The listener's ambient delivery step for a stream on Scratch opened on `session`'s selection generation now,
    /// as `makePipeline` builds it (#695), with the consumer's routing decision.
    static func streamOnScratch(_ listener: WebSocketListener, opened session: HostSession) async -> Stream {
        Stream(dispatcher: AmbientListenerDispatcher(listener: listener, audit: nil,
                                                     selection: await session.selectionGeneration,
                                                     streamTarget: VoiceRouteRig.scratch))
    }

    struct Stream {
        let dispatcher: AmbientListenerDispatcher
        func dispatch(_ request: LocalDispatchRequest, routed: Bool = true) async throws -> UUID? {
            try await dispatcher.dispatch(request, routed: routed)
        }
    }

    @Test func anAmbientRequestToACoveredRouteIsDeliveredAndItsReplyComesBack() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let peers = await rig.listener.installFallbackSyntheticPeers([session])
        let connection = await session.connectionID
        let owner = try await Self.streamOnScratch(rig.listener, opened: session)
            .dispatch(Self.request(connection, to: VoiceRouteRig.deck, binding: "d"))
        let delivered = try #require(await rig.adapter.deliveries.last)
        #expect(delivered.target == "deck" && blockReference(in: delivered.text) == owner)
        #expect(await session.selectedTarget == VoiceRouteRig.scratch)
        // The plain tmux route got a host-minted reference (#230); a reply naming it reaches this device.
        let reference = try #require(owner)
        let reply = recipientText(referenceDescriptor(reference, target: VoiceRouteRig.deck))
        #expect(await peers[0].replyPublicationStatus(reply) == .ready)
        // So does a request-less reply, by last input (#370).
        let requestless = recipientText(referenceDescriptor(nil, target: VoiceRouteRig.deck))
        let route = try #require(await rig.listener.lastInputRoute(requestless))
        #expect(await peers[0].admitsRequestlessReply(requestless, lastInput: route))
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// A request to another route that the consumer did not route (pre-review): no decision, no binding, refused.
    @Test func anotherTargetWithoutTheConsumersRoutingDecisionIsRefused() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        await rig.listener.installFallbackSyntheticPeers([session])
        let connection = await session.connectionID
        await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
            try await Self.streamOnScratch(rig.listener, opened: session)
                .dispatch(Self.request(connection, to: VoiceRouteRig.deck, binding: "d"), routed: false)
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// Ambient dispatch never runs under a route another delivery bound and a spawned task inherited (#688 review).
    @Test func anAmbientDispatchUnderAnInheritedRouteIsRefused() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        await rig.listener.installFallbackSyntheticPeers([session])
        let (connection, generation) = (await session.connectionID, await session.selectionGeneration)
        let inherited = HostSession.VoiceRouted(from: VoiceRouteRig.scratch, to: VoiceRouteRig.deck,
                                                generation: generation)
        await #expect(throws: LocalDispatchRefusal.notAuthorized) {
            try await HostSession.$voiceRouted.withValue(inherited) {
                let request = Self.request(connection, to: VoiceRouteRig.deck, binding: "d")
                return try await Self.streamOnScratch(rig.listener, opened: session).dispatch(request)
            }
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// The local socket's `dispatch` kind (`haild rightyo --reply-to`) binds no route: only the selected target.
    @Test func theLocalSocketCannotAddressAnotherRoute() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        await rig.listener.installFallbackSyntheticPeers([session])
        await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
            try await session.dispatch(Self.request(UUID(), to: VoiceRouteRig.deck, binding: "d"))
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    @Test func anAmbientRequestOutsideTheRoutesIsRefused() async throws {
        let rig = try await VoiceRouteRig.make()
        let routed = try await rig.session(routes: try VoiceRouteRig.routes())
        let unrouted = try await rig.session()
        await rig.listener.installFallbackSyntheticPeers([routed, unrouted])
        // A target that is no route, and a route on a host without the routes file.
        for (session, target, binding) in [(routed, VoiceRouteRig.other, "o"), (unrouted, VoiceRouteRig.deck, "d")] {
            let (connection, stream) = (await session.connectionID, await Self.streamOnScratch(rig.listener,
                                                                                                opened: session))
            await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
                try await stream.dispatch(Self.request(connection, to: target, binding: binding))
            }
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// The owner reselects Deck mid-stream (pre-review blocker): a turn already in flight for the stream's own Scratch
    /// is refused rather than typed there, routed or not, and leaves no claim on Scratch's replies.
    @Test func reselectingAnotherRouteMidStreamAdmitsNothingFromTheOldStream() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let peers = await rig.listener.installFallbackSyntheticPeers([session])
        let (connection, stream) = (await session.connectionID, await Self.streamOnScratch(rig.listener,
                                                                                            opened: session))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.deck))))
        for (target, binding) in [(VoiceRouteRig.scratch, "s"), (VoiceRouteRig.deck, "d")] {
            await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
                try await stream.dispatch(Self.request(connection, to: target, binding: binding))
            }
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        let reply = recipientText(referenceDescriptor(nil, target: VoiceRouteRig.scratch))
        #expect(await rig.listener.lastInputRoute(reply) == nil)
        #expect(!(await peers[0].admitsRequestlessReply(reply)))
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// The owner selects away and back while the stream's turn is in flight (second-key review on #691): the route is
    /// bound on the selection the stream opened on, so the old turn reaches neither the route nor the stream's target.
    @Test func aRoutedTurnFromAStreamOpenedBeforeAwayAndBackIsRefused() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        await rig.listener.installFallbackSyntheticPeers([session])
        let (connection, stream) = (await session.connectionID, await Self.streamOnScratch(rig.listener,
                                                                                            opened: session))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.other))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.scratch))))
        // The route's own generation no longer matches, so the session does not admit it; the stream's own target is
        // admitted but pinned to the old generation.
        await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
            try await stream.dispatch(Self.request(connection, to: VoiceRouteRig.deck, binding: "d"))
        }
        await #expect(throws: LocalDispatchRefusal.selectionChanged) {
            try await stream.dispatch(Self.request(connection, to: VoiceRouteRig.scratch, binding: "s"))
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// The local socket's `dispatch` kind runs under no route, even from a task that inherited one (second-key review
    /// on #691): only the selected target.
    @Test func theLocalSocketIgnoresAnInheritedRoute() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let peers = await rig.listener.installFallbackSyntheticPeers([session])
        let generation = await session.selectionGeneration
        let inherited = HostSession.VoiceRouted(from: VoiceRouteRig.scratch, to: VoiceRouteRig.deck,
                                                generation: generation)
        let key = try #require(await rig.listener.peers.first { $0.value === peers[0] }?.key)
        let request = Self.request(key, to: VoiceRouteRig.deck, binding: "d")
        await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
            try await HostSession.$voiceRouted.withValue(inherited) { try await rig.listener.dispatch(request) }
        }
        #expect(await rig.adapter.deliveries.isEmpty)
        await rig.listener.stop(reason: "synthetic test complete")
    }
}
#endif
