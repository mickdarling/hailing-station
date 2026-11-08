import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

private struct HeldStreamDispatcher: RightyoDispatching {
    let session: HostSession
    let listener: WebSocketListener
    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        .init(request: try await listener.dispatchAmbient(.init(
            connection: await session.connectionID, target: target, binding: binding, text: text
        ), selection: await session.selectionGeneration))
    }
}

@Suite(.frozenGuardBudget) struct HeldAmbientStreamTests {
    @Test(arguments: [false, true])
    func consumerKeepsTheSameRunAfterConfirmationRefusal(capable: Bool) async throws {
        var policy = Policy(guardPatterns: [.init(name: "private rule", regex: "HELD_TOKEN")])
        try policy.allow("tmux:demo", binding: "original", tier: .open)
        let (host, adapter) = try await sessionHost(targets: [.init(name: "demo", binding: "original")], policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame(capabilities: capable ? [HeldRequests.capability] : []))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:demo"))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                             authorizer: PersonalTerminalAuthorizer())
        await listener.installFallbackSyntheticPeers([session])
        let helper = RightyoInputConsumerTests()
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original",
            session: helper.session, allowSynthetic: true,
            dispatcher: HeldStreamDispatcher(session: session, listener: listener))
        _ = try await consumer.consume(helper.start(speakers: "enrolled"))
        let held = try await helper.request(consumer, 0, saying: "HELD_TOKEN")
        #expect(try await !consumer.consume(held))
        #expect(await host.heldRequests.entries.count == (capable ? 1 : 0))
        #expect(await adapter.deliveries.isEmpty)
        #expect(try await consumer.consume(helper.request(consumer, 1, saying: "benign next request")))
        #expect(await adapter.deliveries.count == 1)
        #expect(await host.heldRequests.entries.count == (capable ? 1 : 0))
        await listener.stop(reason: "synthetic complete")
        #expect(await host.heldRequests.entries.count == (capable ? 1 : 0)) // Disconnect never purges content.
    }
}
