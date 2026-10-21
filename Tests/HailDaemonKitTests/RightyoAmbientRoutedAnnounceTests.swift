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
        order.add("dispatch \(request.target)")
        if let refusal { throw refusal }
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
            heard: { order.add("heard") }, streamTarget: "tmux:scratch"
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
        _ = try await accepting.dispatch(text: "hi", target: "tmux:deck", binding: "d")
        #expect(order.all == ["dispatch tmux:deck", "heard", "acknowledge"])
    }

    @Test func aRoutedRequestRefusedBeforeItsHandoffIsNeverAnnounced() async throws {
        let order = Order()
        let refusing = step(refusing: LocalDispatchRefusal.bindingMismatch, order: order)
        await #expect(throws: LocalDispatchRefusal.bindingMismatch) {
            try await refusing.dispatch(text: "hi", target: "tmux:deck", binding: "d")
        }
        #expect(order.all == ["dispatch tmux:deck"])
    }
}
#endif
