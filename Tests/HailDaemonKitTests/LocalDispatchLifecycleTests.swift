import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// A dispatch suspended in registry or adapter work stays bound to the peer's lifecycle and the
/// connection's captured selection (Codex P1s on #195). Synthetic peers and adapters only.
@Suite struct LocalDispatchLifecycleTests {
    @Test func peerEndingDuringTheHandoffRevokesTheMintedRequest() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let listener = try fallbackListener(rig: rig, enabled: false)
        let peer = try #require(await listener.installFallbackSyntheticPeers([session]).first)
        let id = try #require(await listener.connectionID(of: peer))
        await rig.adapter.holdHandoff()
        let dispatch = Task { try await listener.dispatch(dispatchRequest(connection: id)) }
        await rig.adapter.waitForHandoff()
        // The named phone goes away while the adapter is accepting the prompt.
        await peer.finish(reason: "synthetic close")
        await rig.adapter.releaseHandoff()
        await #expect(throws: LocalDispatchRefusal.connectionLost) { try await dispatch.value }
        #expect(await session.replyRequests.isEmpty)
        let frame = recipientText(recipientDescriptor(try #require(await rig.adapter.contexts.last)))
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(frame) }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func selectionMovingDuringTheListingRefusesTheDispatchBeforeAnyHandoff() async throws {
        let adapter = GatedListingFakeAdapter(AdapterTarget(name: "reply", binding: "binding"))
        let registry = Registry()
        try await registry.register(adapter)
        try await registry.register(FakeAdapter(kind: "other", targets: [AdapterTarget(name: "x", binding: "b")]))
        var policy = Policy()
        try policy.allow("tmux:reply", binding: "binding", tier: .open)
        try policy.allow("other:x", binding: "b", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:reply"))))
        await adapter.gateNextListing()
        async let arrival: Void = adapter.nextListingArrival()
        let request = dispatchRequest(connection: UUID(), target: "tmux:reply", binding: "binding")
        let dispatch = Task { try await session.dispatch(request) }
        await arrival
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "other:x"))))
        await adapter.releaseListing()
        await #expect(throws: LocalDispatchRefusal.targetNotSelected) { try await dispatch.value }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func dispatchAuthorizesExactlyOneFrameWhoseIdIsTheUtteranceId() async throws {
        let rig = try await RecipientTestRig.make()
        let authorizer = DispatchCountingAuthorizer()
        let session = HostSession(host: rig.host, authorizer: authorizer, hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let owner = try #require(await session.dispatch(dispatchRequest(connection: UUID())))
        let context = try #require(await rig.adapter.contexts.last)
        #expect(context.id == owner)
        let asked = authorizer.askedTextFrames
        #expect(asked.count == 1)
        #expect(asked.first?.id == context.utteranceID)
        #expect(asked.first?.source == HostSession.dispatchDevice)
        #expect(asked.first?.target == RecipientTestRig.target)
    }
}
