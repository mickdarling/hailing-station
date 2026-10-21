import Foundation
import Testing
@testable import HailDaemonKit

/// A dispatcher with only the plain delivery step, so a routed request takes the protocol's default.
private actor PlainRecordingDispatcher: RightyoDispatching {
    private(set) var targets: [String] = []

    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        targets.append(target)
        return RightyoDispatchReceipt(request: nil)
    }
}

/// Holds a route's binding lookup until released, so a test can act while the consumer is suspended in it.
private actor BindingGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var isWaiting: Bool { !waiters.isEmpty }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Second-key reviews on #707: a turn routes only when both its transcript and its attention record call it the
/// owner's; the stream's own name alone is typed as before; a dispatcher that cannot bind a route refuses it.
extension RightyoInputConsumerTests {
    @Test(arguments: [("owner", "participant"), ("owner", nil), ("participant", "owner")] as [(String, String?)])
    func aTurnOnlyOneRecordCallsTheOwnersIsNeverRouted(_ transcript: String, _ attention: String?) async throws {
        let (consumer, dispatcher) = try await routingRig()
        let event = try await request(consumer, 0, saying: "Deck, add a slide.", role: transcript,
                                      attentionRole: .some(attention))
        #expect(try await consumer.consume(event))
        #expect(await dispatcher.calls.map(\.target) == ["tmux:demo"])
        #expect(await dispatcher.calls.allSatisfy { !$0.routed })
        #expect(await consumer.lastRouteRefusal == nil)
    }

    @Test func theStreamsOwnNameAloneIsTypedToItAsBefore() async throws {
        let (consumer, dispatcher) = try await routingRig()
        #expect(try await consumer.consume(request(consumer, 0, saying: "Scratch.")))
        #expect(await dispatcher.calls.map(\.target) == ["tmux:demo"])
        #expect(await consumer.lastRouteRefusal == nil)
    }

    @Test func theStreamsOwnNameWithARequestIsTypedToItUnrouted() async throws {
        let (consumer, dispatcher) = try await routingRig()
        #expect(try await consumer.consume(request(consumer, 0, saying: "Scratch, add a slide.")))
        #expect(await dispatcher.calls.map(\.target) == ["tmux:demo"])
        #expect(await dispatcher.calls.allSatisfy { !$0.routed && $0.binding == "original" })
    }

    /// No event enters while the consumer waits on a route's binding: the lookup suspends inside the busy guard.
    @Test func noEventEntersWhileARoutesBindingIsLookedUp() async throws {
        let gate = BindingGate()
        let routing = RightyoVoiceRouting(routes: try Self.voiceRouting().routes) { target in
            await gate.wait()
            return target == "tmux:deck" ? "deck-binding" : nil
        }
        let dispatcher = VoiceRouteRecordingDispatcher()
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original", session: session,
                                                allowSynthetic: true, dispatcher: dispatcher, routing: routing)
        _ = try await consumer.consume(start(speakers: "enrolled"))
        let first = try await request(consumer, 0, saying: "Deck, add a slide.")
        let routed = Task { try await consumer.consume(first) }
        for _ in 0..<10_000 where !(await gate.isWaiting) { await Task.yield() }
        #expect(await gate.isWaiting)
        // Any well-formed event is refused while busy, before the sequence and duplicate checks.
        await #expect(throws: RightyoInputError.invalidLifecycle) { try await consumer.consume(first) }
        await gate.release()
        #expect(try await routed.value)
        #expect(await dispatcher.calls.map(\.target) == ["tmux:deck"])
    }

    @Test func aDispatcherThatCannotBindARouteRefusesItAndTheStreamGoesOn() async throws {
        let dispatcher = PlainRecordingDispatcher()
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original", session: session,
                                                allowSynthetic: true, dispatcher: dispatcher,
                                                routing: try Self.voiceRouting())
        _ = try await consumer.consume(start(speakers: "enrolled"))
        #expect(try await !consumer.consume(request(consumer, 0, saying: "Deck, add a slide.")))
        #expect(await consumer.lastRouteRefusal == .notDelivered("Deck"))
        #expect(await dispatcher.targets.isEmpty)
        #expect(try await consumer.consume(request(consumer, 1, saying: "What's next?")))
        #expect(await dispatcher.targets == ["tmux:demo"])
    }
}
