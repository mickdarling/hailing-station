#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// What happened, in order.
private final class Order: Sendable {
    private let steps = Mutex<[String]>([])
    func add(_ step: String) { steps.withLock { $0.append(step) } }
    var all: [String] { steps.withLock { $0 } }
}

/// Refuses every dispatch with `refusal`, or accepts it.
private struct ScriptedAmbientDispatcher: RightyoAmbientDispatching {
    let refusal: LocalDispatchRefusal?
    let order: Order

    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        try await dispatch(request, routed: false)
    }

    func dispatch(_ request: LocalDispatchRequest, routed: Bool) async throws -> UUID? {
        order.add("dispatch \(request.target)\(routed ? " routed" : "")")
        if let refusal { throw refusal }
        return nil
    }
}

/// Only the plain delivery step, so a routed request takes the protocol's default.
private struct PlainAmbientDispatcher: RightyoAmbientDispatching {
    let order: Order

    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        order.add("dispatch \(request.target)")
        return nil
    }
}

/// A routed ambient request (#636, pre-review) is shown to the device and acknowledged only once handed off, so a
/// route that refuses it never looks sent; the stream's own requests keep announcing before they are typed.
@Suite struct RightyoAmbientRoutedAnnounceTests {
    private func step(refusing refusal: LocalDispatchRefusal?, order: Order) -> RightyoAmbientDispatchStep {
        RightyoAmbientDispatchStep(
            connection: UUID(), dispatcher: ScriptedAmbientDispatcher(refusal: refusal, order: order),
            acknowledge: { order.add("acknowledge") },
            heard: { order.add("heard") }
        )
    }

    @Test func theStreamsOwnRequestAnnouncesBeforeItIsTyped() async throws {
        let order = Order()
        let accepting = step(refusing: LocalDispatchRefusal?.none, order: order)
        _ = try await accepting.dispatch(text: "hi", target: "tmux:scratch", binding: "s")
        #expect(order.all == ["heard", "acknowledge", "dispatch tmux:scratch"])
    }

    @Test func aRoutedRequestAnnouncesOnlyAfterItsHandoff() async throws {
        let order = Order()
        let accepting = step(refusing: LocalDispatchRefusal?.none, order: order)
        _ = try await accepting.dispatch(text: "hi", target: "tmux:deck", binding: "d", routed: true)
        #expect(order.all == ["dispatch tmux:deck routed", "heard", "acknowledge"])
    }

    @Test func aRoutedRequestRefusedBeforeItsHandoffIsNeverAnnounced() async throws {
        let order = Order()
        let refusing = step(refusing: LocalDispatchRefusal.bindingMismatch, order: order)
        await #expect(throws: LocalDispatchRefusal.bindingMismatch) {
            try await refusing.dispatch(text: "hi", target: "tmux:deck", binding: "d", routed: true)
        }
        #expect(order.all == ["dispatch tmux:deck routed"])
    }

    /// A dispatcher that cannot bind a route refuses a routed request (second-key review on #707), never announced.
    @Test func aDispatcherWithoutRoutingRefusesARoutedRequest() async throws {
        let order = Order()
        let plain = RightyoAmbientDispatchStep(connection: UUID(), dispatcher: PlainAmbientDispatcher(order: order),
                                               acknowledge: { order.add("acknowledge") }, heard: { order.add("heard") })
        await #expect(throws: LocalDispatchRefusal.notAuthorized) {
            try await plain.dispatch(text: "hi", target: "tmux:deck", binding: "d", routed: true)
        }
        #expect(order.all.isEmpty)
        _ = try await plain.dispatch(text: "hi", target: "tmux:scratch", binding: "s")
        #expect(order.all == ["heard", "acknowledge", "dispatch tmux:scratch"])
    }
}
#endif
