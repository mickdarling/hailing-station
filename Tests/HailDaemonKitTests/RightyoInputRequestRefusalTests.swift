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
        let rig = try await requestRefusalRig(sessionDispatch: sessionDispatch)
        let (consumer, host, adapter) = (rig.consumer, rig.host, rig.adapter)
        _ = try await consumer.consume(start(speakers: "enrolled"))
        #expect(await consumer.requestRefusal == nil)
        let refused = try await request(consumer, 0, saying: "sudo SYNTHETIC_TOKEN")
        let evidence = RightyoGuardRefusal()
        #expect(try await !RightyoGuardRefusal.$current.withValue(evidence) { try await consumer.consume(refused) })
        #expect(await consumer.lastReceipt == nil)
        #expect(await consumer.lastDeliveryRefusal == .confirmationRequired)
        #expect(evidence.ruleTokens == "sudo+custom")
        #expect(await adapter.deliveries.isEmpty)
        let hash = try DeliveryRequest(target: "tmux:demo", binding: "original",
                                       lines: [refused.prompt(speakers: "enrolled", target: "tmux:demo")],
                                       device: RightyoHostDispatcher.device).confirmationHash
        // The host dispatcher cancels the stored read-back; the session path does so from #847's follow-up.
        if !sessionDispatch { #expect(await host.cancel(hash) == false) }
        #expect(try await !consumer.consume(refused)) // Never retry a refused request.
        #expect(try await consumer.consume(request(consumer, 1, saying: "SYNTHETIC_BENIGN")))
        #expect(await consumer.lastDeliveryRefusal == nil)
        #expect(await adapter.deliveries.count == 1)
        _ = try await consumer.consume(event("session", sequence: 9, extra: [
            "phase": "stopped", "emitted_at_ms": 30_000
        ]))
        try await consumer.finish()
        #expect(await consumer.requestRefusal == .confirmationRequired)
    }

    private struct RequestRefusalRig {
        let consumer: RightyoInputConsumer
        let host: HailHost
        let adapter: FakeAdapter
    }

    private func requestRefusalRig(sessionDispatch: Bool) async throws -> RequestRefusalRig {
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
        return RequestRefusalRig(consumer: consumer, host: host, adapter: adapter)
    }

    @Test(arguments: [LocalDispatchRefusal.confirmationRequired, .capacityExceeded])
    func requestRefusalsLeaveTheOwnTargetUsable(_ refusal: LocalDispatchRefusal) async throws {
        let (consumer, dispatcher) = try await routingRig()
        #expect(await consumer.requestRefusal == nil)
        await dispatcher.refuse(refusal)
        let refused = try await request(consumer, 0, saying: "SYNTHETIC_REQUEST")
        #expect(try await !consumer.consume(refused))
        #expect(await consumer.lastDeliveryRefusal != nil)
        let expected: RightyoInputError = refusal == .confirmationRequired ? .confirmationRequired : .capacity
        #expect(await consumer.requestRefusal == expected)
        await dispatcher.refuse(nil)
        #expect(try await !consumer.consume(refused)) // Never retry a refused request.
        #expect(try await consumer.consume(request(consumer, 1, saying: "SYNTHETIC_NEXT")))
        #expect(await consumer.lastDeliveryRefusal == nil)
        #expect(await dispatcher.calls.count == 1)
        _ = try await consumer.consume(event("session", sequence: 9, extra: [
            "phase": "stopped", "emitted_at_ms": 30_000
        ]))
        try await consumer.finish()
        #expect(await consumer.requestRefusal == expected)
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
        #expect(captured.ruleTokens == "custom+custom")
        captured.hits.withLock { $0 = ["force push", "rm -rf", "text=SECRET\n"] }
        #expect(captured.ruleTokens == "force_push+rm_-rf+custom")
        captured.hits.withLock { $0 = [] }
        #expect(captured.ruleTokens == "none")
    }

    @Test(arguments: [LocalDispatchRefusal.confirmationRequired, .capacityExceeded])
    func theFirstRefusalSurvivesADifferentRefusalAndASuccess(_ first: LocalDispatchRefusal) async throws {
        let (consumer, dispatcher) = try await routingRig()
        let second: LocalDispatchRefusal = first == .confirmationRequired ? .capacityExceeded : .confirmationRequired
        let expected: RightyoInputError = first == .confirmationRequired ? .confirmationRequired : .capacity
        for (index, refusal) in [first, second].enumerated() {
            await dispatcher.refuse(refusal)
            #expect(try await !consumer.consume(request(consumer, index, saying: "SYNTHETIC_REQUEST")))
            #expect(await consumer.lastDeliveryRefusal == refusal)
            #expect(await consumer.requestRefusal == expected)
        }
        await dispatcher.refuse(nil)
        #expect(try await consumer.consume(request(consumer, 2, saying: "SYNTHETIC_BENIGN")))
        #expect(await consumer.requestRefusal == expected)
    }
}
