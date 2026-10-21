import Foundation
import Testing
@testable import HailDaemonKit

/// Records what the consumer dispatches, or refuses every dispatch with `refusal`.
private actor VoiceRouteRecordingDispatcher: RightyoDispatching {
    struct Call {
        let target: String
        let binding: String
        let text: String
        var routed = false
    }

    private(set) var calls: [Call] = []
    var refusal: LocalDispatchRefusal?

    func refuse(_ refusal: LocalDispatchRefusal?) { self.refusal = refusal }

    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        try await dispatch(text: text, target: target, binding: binding, routed: false)
    }

    func dispatch(text: String, target: String, binding: String, routed: Bool) async throws -> RightyoDispatchReceipt {
        if let refusal { throw refusal }
        calls.append(Call(target: target, binding: binding, text: text, routed: routed))
        return RightyoDispatchReceipt(request: nil)
    }
}

/// Ambient voice routing in the RightyO consumer (#636, slice 4b): the owner's own turn on an enrolled session may
/// name another route; nothing else routes, and a refusal sends nothing and ends nothing. Synthetic events only.
extension RightyoInputConsumerTests {
    static func voiceRouting() throws -> RightyoVoiceRouting {
        let routes = try VoiceRoutes(defaultTarget: "tmux:demo", routes: [
            .init(target: "tmux:demo", name: "Scratch"), .init(target: "tmux:deck", name: "Deck"),
            .init(target: "tmux:voice", name: "Voice Work")
        ])
        return RightyoVoiceRouting(routes: routes) { target in target == "tmux:deck" ? "deck-binding" : nil }
    }

    private func routingRig(
        target: String = "tmux:demo", speakers: String = "enrolled"
    ) async throws -> (RightyoInputConsumer, VoiceRouteRecordingDispatcher) {
        let dispatcher = VoiceRouteRecordingDispatcher()
        let consumer = try RightyoInputConsumer(host: nil, target: target, binding: "original", session: session,
                                                allowSynthetic: true, dispatcher: dispatcher,
                                                routing: try Self.voiceRouting())
        _ = try await consumer.consume(start(speakers: speakers))
        return (consumer, dispatcher)
    }

    /// Transcript, attention and request for one turn saying `text`; `index` keeps ids, sequences and times apart.
    private func request(
        _ consumer: RightyoInputConsumer, _ index: Int, saying text: String, role: String? = "owner"
    ) async throws -> RightyoInputEvent {
        let (id, sequence, end) = ("r\(index)", 2 + index * 3, 10_000 * (index + 1))
        var final = roleTurn(id, role: role, start: end - 800, end: end)
        final["text"] = text
        var decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1"]
        if let role { decision["role"] = role }
        _ = try await consumer.consume(event("transcript", sequence: sequence,
                                             extra: ["turn": final, "emitted_at_ms": end + 100]))
        _ = try await consumer.consume(event("attention", sequence: sequence + 1, extra: [
            "utterance_id": id, "request_id": "\(session):\(id)", "decision": decision, "emitted_at_ms": end + 100
        ]))
        return try event("request", sequence: sequence + 2, extra: [
            "request_id": "\(session):\(id)", "turn": final, "decision": decision, "context": ["turns": []],
            "decision_at_ms": end + 100,
            "emitted_at_ms": end + 100
        ])
    }

    @Test func theOwnersNamedRequestGoesToThatRouteWithItsReplyBlock() async throws {
        let (consumer, dispatcher) = try await routingRig()
        #expect(try await consumer.consume(request(consumer, 0, saying: "Deck, add a slide on pricing.")))
        let call = try #require(await dispatcher.calls.first)
        #expect(call.target == "tmux:deck" && call.binding == "deck-binding" && call.routed)
        #expect(call.text.hasSuffix(RightyoInputEvent.replyBlock(target: "tmux:deck")))
        #expect(await consumer.lastRouteRefusal == nil)
    }

    /// Owner only: anyone else's "Deck, …", or any turn on an anonymous session, is a request to the target.
    @Test func otherSpeakersAndAnonymousSessionsAreNeverRouted() async throws {
        let (enrolled, toTarget) = try await routingRig()
        #expect(try await enrolled.consume(request(enrolled, 0, saying: "Deck, add a slide.", role: "participant")))
        let (anonymous, alsoToTarget) = try await routingRig(speakers: "anonymous")
        #expect(try await anonymous.consume(request(anonymous, 0, saying: "Deck, add a slide.", role: nil)))
        for dispatcher in [toTarget, alsoToTarget] {
            #expect(await dispatcher.calls.map(\.target) == ["tmux:demo"])
            #expect(await dispatcher.calls.first?.binding == "original")
            #expect(await dispatcher.calls.allSatisfy { !$0.routed })
        }
    }

    @Test func aTargetThatIsNoRouteKeepsEveryRequest() async throws {
        let (consumer, dispatcher) = try await routingRig(target: "tmux:other")
        #expect(try await consumer.consume(request(consumer, 0, saying: "Deck, add a slide.")))
        #expect(await dispatcher.calls.map(\.target) == ["tmux:other"])
    }

    /// No silent fallback: each refusal sends nothing anywhere, says why, and the stream goes on.
    @Test(arguments: [
        ("Voice Work, run the tests.", RightyoVoiceRouting.Refusal.notDelivered("Voice Work")),
        ("Deck.", .nothingToSay("Deck")), ("Scratchy, are you there?", .unclear)
    ])
    func aRequestARouteCannotTakeIsHeldBackAndTheStreamGoesOn(
        _ text: String, _ refusal: RightyoVoiceRouting.Refusal
    ) async throws {
        let (consumer, dispatcher) = try await routingRig()
        #expect(try await !consumer.consume(request(consumer, 0, saying: text)))
        #expect(await consumer.lastRouteRefusal == refusal)
        #expect(await dispatcher.calls.isEmpty)
        #expect(try await consumer.consume(request(consumer, 1, saying: "What's next?")))
        #expect(await consumer.lastRouteRefusal == nil)
        #expect(await dispatcher.calls.map(\.target) == ["tmux:demo"])
    }

    /// A route that goes offline between addressing and handoff refuses that request only; the target's own
    /// refusal still ends the stream, as before.
    @Test func aRoutedDispatchRefusedBeforeHandoffEndsNothing() async throws {
        let (consumer, dispatcher) = try await routingRig()
        await dispatcher.refuse(.bindingMismatch)
        #expect(try await !consumer.consume(request(consumer, 0, saying: "Deck, add a slide.")))
        #expect(await consumer.lastRouteRefusal == .notDelivered("Deck"))
        let unrouted = try await request(consumer, 1, saying: "What's next?")
        await #expect(throws: LocalDispatchRefusal.bindingMismatch) { try await consumer.consume(unrouted) }
    }

    @Test func refusalTokensCarryTheReasonOnly() {
        #expect(RightyoVoiceRouting.Refusal.notDelivered("Deck").token == "reason=not_delivered")
        #expect(RightyoVoiceRouting.Refusal.nothingToSay("Deck").token == "reason=nothing_to_say")
        #expect(RightyoVoiceRouting.Refusal.unclear.token == "reason=unclear")
    }
}

#if os(macOS)
extension RightyoInputConsumerTests {
    /// End to end through the listener (#636, review gate on #691): only the owner's own "Deck, …" reaches Deck,
    /// chosen by the host's own route match. A guest's is typed, un-routed, into the stream's own target; and words
    /// sent to Deck without the owner's routing decision are refused, with nothing typed.
    @Test func onlyTheOwnersNamedRequestReachesTheRouteThroughTheListener() async throws {
        let rig = try await VoiceRouteRig.make()
        let routes = try VoiceRouteRig.routes()
        let host = try await rig.session(routes: routes)
        _ = await rig.listener.installFallbackSyntheticPeers([host])
        let connection = await host.connectionID
        let stream = AmbientListenerDispatcher(listener: rig.listener, audit: nil,
                                               selection: await host.selectionGeneration,
                                               streamTarget: VoiceRouteRig.scratch)
        let routing = RightyoVoiceRouting(routes: routes) { await rig.listener.voiceRouteBinding($0) }
        let consumer = try RightyoInputConsumer(
            host: nil, target: VoiceRouteRig.scratch, binding: "s", session: session, allowSynthetic: true,
            dispatcher: RightyoAmbientDispatchStep(connection: connection, dispatcher: stream), routing: routing
        )
        _ = try await consumer.consume(start(speakers: "enrolled"))
        #expect(try await consumer.consume(request(consumer, 0, saying: "Deck, add a slide.", role: "participant")))
        #expect(await rig.adapter.deliveries.map(\.target) == ["scratch"])
        #expect(try await consumer.consume(request(consumer, 1, saying: "Deck, add a slide on pricing.")))
        #expect(await rig.adapter.deliveries.map(\.target) == ["scratch", "deck"])
        let unrouted = VoiceRouteAmbientAuthorityTests.request(connection, to: VoiceRouteRig.deck, binding: "d")
        await #expect(throws: LocalDispatchRefusal.targetNotSelected) {
            try await stream.dispatch(unrouted, routed: false)
        }
        #expect(await rig.adapter.deliveries.count == 2)
        await rig.listener.stop(reason: "synthetic test complete")
    }
}
#endif
