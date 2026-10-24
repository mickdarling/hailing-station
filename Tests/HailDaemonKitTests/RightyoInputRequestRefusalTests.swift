import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

private struct SessionRequestDispatcher: RightyoDispatching {
    let session: HostSession

    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        let request = try await session.dispatch(.init(
            connection: UUID(), target: target, binding: binding, text: text
        ))
        return .init(request: request)
    }
}

extension RightyoInputConsumerTests {
    @Test(arguments: [false, true])
    func guardRefusalKeepsTheRunForEitherDispatcher(sessionDispatch: Bool) async throws {
        let (consumer, host, adapter) = try await requestRefusalRig(sessionDispatch: sessionDispatch)
        _ = try await consumer.consume(start(speakers: "enrolled"))
        let refused = try await request(consumer, 0, saying: "sudo SYNTHETIC_TOKEN")
        #expect(try await !consumer.consume(refused))
        #expect(await consumer.lastReceipt == nil)
        #expect(await consumer.lastRouteRefusal?.token == "reason=confirmation_required rules=sudo+custom")
        #expect(await adapter.deliveries.isEmpty)
        let hash = try DeliveryRequest(target: "tmux:demo", binding: "original",
                                       lines: [refused.prompt(speakers: "enrolled", target: "tmux:demo")],
                                       device: RightyoHostDispatcher.device).confirmationHash
        #expect(await host.cancel(hash) == false)
        #expect(try await !consumer.consume(refused)) // Never retry a refused request.
        #expect(try await consumer.consume(request(consumer, 1, saying: "SYNTHETIC_BENIGN")))
        #expect(await consumer.lastRouteRefusal == nil)
        #expect(await adapter.deliveries.count == 1)
        _ = try await consumer.consume(event("session", sequence: 9, extra: [
            "phase": "stopped", "emitted_at_ms": 30_000
        ]))
        try await consumer.finish()
    }

    private func requestRefusalRig(
        sessionDispatch: Bool
    ) async throws -> (RightyoInputConsumer, HailHost, FakeAdapter) {
        let adapter = FakeAdapter(kind: "tmux", targets: [.init(name: "demo", binding: "original")])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: DangerousPatternGuard.defaults + [
            .init(name: "SYNTHETIC_PRIVATE_RULE\ntext=hidden", regex: "SYNTHETIC_TOKEN")
        ])
        try policy.allow("tmux:demo", binding: "original", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let dispatcher: any RightyoDispatching
        if sessionDispatch {
            let selected = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
            _ = await selected.receive(helloFrame())
            _ = await selected.receive(sessionFrame(payload: .control(.select(targetID: "tmux:demo"))))
            dispatcher = SessionRequestDispatcher(session: selected)
        } else {
            dispatcher = RightyoHostDispatcher(host: host)
        }
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original", session: session,
                                                allowSynthetic: true, dispatcher: dispatcher)
        return (consumer, host, adapter)
    }

    @Test(arguments: [LocalDispatchRefusal.confirmationRequired, .capacityExceeded])
    func requestRefusalsLeaveTheOwnTargetUsable(_ refusal: LocalDispatchRefusal) async throws {
        let (consumer, dispatcher) = try await routingRig()
        await dispatcher.refuse(refusal)
        #expect(try await !consumer.consume(request(consumer, 0, saying: "SYNTHETIC_REQUEST")))
        #expect(await consumer.lastRouteRefusal != nil)
        await dispatcher.refuse(nil)
        #expect(try await consumer.consume(request(consumer, 1, saying: "SYNTHETIC_NEXT")))
        #expect(await dispatcher.calls.count == 1)
    }

    @Test(arguments: [LocalDispatchRefusal.bindingMismatch, .selectionChanged, .deliveryRefused])
    func targetRefusalsStillEndTheOwnRun(_ refusal: LocalDispatchRefusal) async throws {
        let (consumer, dispatcher) = try await routingRig()
        await dispatcher.refuse(refusal)
        let refused = try await request(consumer, 0, saying: "SYNTHETIC_REQUEST")
        await #expect(throws: refusal) { try await consumer.consume(refused) }
        await #expect(throws: RightyoInputError.invalidLifecycle) {
            try await consumer.consume(event("session", sequence: 9, extra: [
                "phase": "stopped", "emitted_at_ms": 30_000
            ]))
        }
        #expect(await dispatcher.calls.isEmpty)
    }

    @Test func guardRuleTokensNeverUseCustomNamesOrPatterns() {
        let captured = RightyoGuardRefusal()
        captured.record(["sudo", "SYNTHETIC_TEXT"], patterns: [
            .init(name: "sudo", regex: "SYNTHETIC_PATTERN"),
            .init(name: "SYNTHETIC_TEXT", regex: "SYNTHETIC_PATTERN")
        ])
        #expect(RightyoVoiceRouting.Refusal.confirmationRequired(captured.hits.withLock { $0 }).token
                == "reason=confirmation_required rules=custom+custom")
        #expect(RightyoVoiceRouting.Refusal.confirmationRequired(["force push", "rm -rf", "text=SECRET\n"]).token
                == "reason=confirmation_required rules=force_push+rm_-rf+custom")
        #expect(RightyoVoiceRouting.Refusal.confirmationRequired([]).token
                == "reason=confirmation_required rules=none")
    }
}
