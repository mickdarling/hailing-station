import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Never-started transports and direct sessions: every refusal here happens before any handoff.
@Suite struct LocalDispatchRefusalTests {
    @Test func unknownAndEndedConnectionsRefuseWithoutFallback() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let peer = try #require(await listener.installFallbackSyntheticPeers([await rig.session()]).first)
        let id = try #require(await listener.connectionID(of: peer))
        await #expect(throws: LocalDispatchRefusal.unknownConnection) {
            try await listener.dispatch(dispatchRequest(connection: UUID()))
        }
        await peer.finish(reason: "synthetic close")
        #expect(await listener.peers.count == 1)
        await #expect(throws: LocalDispatchRefusal.connectionEnded) {
            try await listener.dispatch(dispatchRequest(connection: id))
        }
        #expect(await rig.adapter.contexts.isEmpty)
        await listener.stop(reason: "synthetic test complete")
        await #expect(throws: WebSocketListenerError.stoppedBeforeReady) {
            try await listener.dispatch(dispatchRequest(connection: id))
        }
    }

    @Test func sessionStateAndSelectionGateTheDispatch() async throws {
        let rig = try await RecipientTestRig.make()
        let unnegotiated = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        let unselected = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await unselected.receive(helloFrame())
        let elsewhere = await rig.session()
        _ = await elsewhere.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        let cases: [(HostSession, LocalDispatchRefusal)] = [
            (unnegotiated, .sessionNotReady), (unselected, .targetNotSelected), (elsewhere, .targetNotSelected)
        ]
        for (session, refusal) in cases {
            await #expect(throws: refusal) { try await session.dispatch(dispatchRequest(connection: UUID())) }
        }
        let selected = await rig.session()
        await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
            try await selected.dispatch(dispatchRequest(connection: UUID(), target: "recipient:other"))
        }
        #expect(await rig.adapter.contexts.isEmpty)
    }

    @Test func connectionProbeSessionsAreRefusedByTheAuthorizerBeforeAnythingElse() async throws {
        let rig = try await RecipientTestRig.make()
        let probe = HostSession(host: rig.host, hostName: "mac-test")
        _ = await probe.receive(helloFrame())
        // Force the state a probe can never reach through its own frames; the authorizer still refuses.
        await probe.forceSelection(RecipientTestRig.target)
        #expect(await probe.selectedTarget == RecipientTestRig.target)
        await #expect(throws: LocalDispatchRefusal.notAuthorized) {
            try await probe.dispatch(dispatchRequest(connection: UUID()))
        }
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await probe.replyRequests.isEmpty)
    }

    @Test func pinnedBindingMustEqualTheCurrentListing() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        await #expect(throws: LocalDispatchRefusal.bindingMismatch) {
            try await session.dispatch(dispatchRequest(connection: UUID(), binding: "stale-binding"))
        }
        // The program behind the name changed since the caller listed it: refuse, never follow the rebind.
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "replacement")])
        await #expect(throws: LocalDispatchRefusal.bindingMismatch) {
            try await session.dispatch(dispatchRequest(connection: UUID()))
        }
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await session.replyRequests.isEmpty)
    }

    @Test func selectionChangeAndExpiryRevokeTheDispatchedRequest() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let listener = try fallbackListener(rig: rig, enabled: true)
        await listener.installFallbackSyntheticPeers([session])
        let owner = try #require(await session.dispatch(dispatchRequest(connection: UUID())))
        let frame = recipientText(recipientDescriptor(try #require(await rig.adapter.contexts.last)))
        #expect(try #require(await rig.adapter.contexts.last).id == owner)
        #expect(await session.replyPublicationStatus(frame) == .ready)
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        #expect(!(await session.acceptsHostReply(frame)))
        // Reselecting the target cannot revive the old request, and the fallback never redirects it.
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        #expect(!(await session.acceptsHostReply(frame)))
        await #expect(throws: LocalReplyRefusal.noRecipient) { try await listener.publish(frame) }
        let later = recipientText(recipientDescriptor(try #require(await rig.adapter.contexts.last)))
        _ = try #require(await session.dispatch(dispatchRequest(connection: UUID())))
        let fresh = recipientText(recipientDescriptor(try #require(await rig.adapter.contexts.last)))
        #expect(!(await session.acceptsHostReply(later)))
        rig.clock.advance(120_000)
        #expect(!(await session.acceptsHostReply(fresh)))
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func confirmationRequiredRefusesAndRemovesTheMintedRecord() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
            try await session.dispatch(dispatchRequest(connection: UUID(), text: "synthetic guarded command"))
        }
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await session.replyRequests.isEmpty)
    }

    @Test func liveRequestCapacityRefusesBeforeHandoff() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        for _ in 0..<HostReplyRequest.capacity {
            _ = try #require(await session.dispatch(dispatchRequest(connection: UUID())))
        }
        await #expect(throws: LocalDispatchRefusal.capacityExceeded) {
            try await session.dispatch(dispatchRequest(connection: UUID()))
        }
        #expect(await rig.adapter.contexts.count == HostReplyRequest.capacity)
    }

    @Test func legacyAdapterDeliversWithoutOwnership() async throws {
        var policy = Policy()
        try policy.allow("tmux:reply", binding: "binding", tier: .open)
        let (host, adapter) = try await sessionHost(
            targets: [AdapterTarget(name: "reply", binding: "binding")], policy: policy
        )
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:reply"))))
        let request = dispatchRequest(connection: UUID(), target: "tmux:reply", binding: "binding")
        // Delivered, but no lease is invented: the caller sees `request: null` and nobody owns a reply.
        #expect(try await session.dispatch(request) == nil)
        #expect(await adapter.deliveries == [.init(target: "reply", text: "synthetic input", binding: "binding")])
        #expect(await session.replyRequests.isEmpty)
        await #expect(throws: LocalDispatchRefusal.bindingMismatch) {
            try await session.dispatch(dispatchRequest(connection: UUID(), target: "tmux:reply", binding: "stale"))
        }
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func contextualAdapterWithoutALeaseRefusesBeforeHandoff() async throws {
        let adapter = LeaselessContextAdapter()
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("leaseless:reply", binding: "binding", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "leaseless:reply"))))
        let request = dispatchRequest(connection: UUID(), target: "leaseless:reply", binding: "binding")
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await session.dispatch(request) }
        #expect(await adapter.contexts.isEmpty)
        #expect(await session.replyRequests.isEmpty)
    }
}

/// Structured input without cooperative binding authority: it must not masquerade as a reply bridge.
private actor LeaselessContextAdapter: ProviderContextDelivering {
    nonisolated let kind = "leaseless"
    private(set) var contexts: [ProviderTurnContext] = []

    func listTargets() async throws -> [AdapterTarget] { [AdapterTarget(name: "reply", binding: "binding")] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {}
    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        contexts.append(context)
    }
}
