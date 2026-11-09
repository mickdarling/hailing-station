import Testing
@testable import HailDaemonKit

extension RightyoInputConsumerTests {
    @Test(arguments: [false, true], [0, 2])
    func dialogRefusalKeepsTypedEvidenceAndTheNextRequestUsable(routed: Bool, earlier: Int) async throws {
        let (consumer, dispatcher) = try await routingRig()
        let block = DialogBlock(cause: .uninspectable, effects: .enterMayHaveExecuted)
        let refusal = LocalDispatchRefusal.blockedByDialog(block, earlierDelivered: earlier)
        await dispatcher.refuse(refusal)
        let words = routed ? "Deck, add a slide." : "What's next?"
        let first = try await request(consumer, 0, saying: words)
        #expect(try await !consumer.consume(first))
        #expect(await consumer.lastDeliveryRefusal == refusal)
        #expect(await consumer.lastRouteRefusal == nil)
        #expect(await consumer.lastReceipt == nil)
        await dispatcher.refuse(nil)
        #expect(try await !consumer.consume(first))
        #expect(try await consumer.consume(request(consumer, 1, saying: words)))
        #expect(await consumer.lastDeliveryRefusal == nil)
        #expect(await consumer.lastReceipt != nil)
        #expect(await dispatcher.calls.count == 1)
    }
}
