import Foundation
import Testing
@testable import HailDaemonKit

/// #894 ask 3: an un-routed request the target refused because its input already holds unsent text sends nothing,
/// says why in `lastDeliveryRefusal`, and ends nothing, so the next request is tried as usual. Every other refusal of
/// the stream's own target, except confirmation/capacity (#847), still ends the consumer. Synthetic events and a
/// recording dispatcher only.
extension RightyoInputConsumerTests {
    @Test func pendingInputRefusesThatRequestOnlyAndTheNextIsTyped() async throws {
        let (consumer, dispatcher) = try await routingRig()
        await dispatcher.refuse(.inputPending)
        #expect(try await !consumer.consume(request(consumer, 0, saying: "What's next?")))
        #expect(await consumer.lastDeliveryRefusal == .inputPending)
        #expect(await consumer.lastRouteRefusal == nil)
        #expect(await consumer.lastReceipt == nil)
        #expect(await dispatcher.calls.isEmpty)
        // The input was cleared meanwhile: the next request is dispatched, and the refusal is not carried over.
        await dispatcher.refuse(nil)
        #expect(try await consumer.consume(request(consumer, 1, saying: "And after that?")))
        #expect(await consumer.lastDeliveryRefusal == nil)
        #expect(await consumer.lastReceipt != nil)
        #expect(await dispatcher.calls.map(\.target) == ["tmux:demo"])
    }

    @Test func pendingInputThatPersistsRefusesEachRequestInTurn() async throws {
        let (consumer, dispatcher) = try await routingRig()
        await dispatcher.refuse(.inputPending)
        for index in 0..<3 {
            #expect(try await !consumer.consume(request(consumer, index, saying: "Request \(index).")))
            #expect(await consumer.lastDeliveryRefusal == .inputPending)
        }
        #expect(await dispatcher.calls.isEmpty)
    }

    /// Selection, binding, authorization and delivery refusals still end the consumer (#894, #847).
    @Test(arguments: [LocalDispatchRefusal.deliveryRefused, .bindingMismatch, .selectionChanged, .notAuthorized])
    func everyOtherRefusalOfTheTargetStillEndsTheConsumer(_ refusal: LocalDispatchRefusal) async throws {
        let (consumer, dispatcher) = try await routingRig()
        await dispatcher.refuse(refusal)
        let first = try await request(consumer, 0, saying: "What's next?")
        await #expect(throws: refusal) { try await consumer.consume(first) }
        #expect(await consumer.lastDeliveryRefusal == nil)
        await dispatcher.refuse(nil)
        await #expect(throws: RightyoInputError.invalidLifecycle) {
            _ = try await request(consumer, 1, saying: "And after that?")
        }
        #expect(await dispatcher.calls.isEmpty)
    }

    /// A routed request (#636) the route refuses for pending input stays a route refusal, told as before.
    @Test func aRoutedRequestRefusedForPendingInputStaysARouteRefusal() async throws {
        let (consumer, dispatcher) = try await routingRig()
        await dispatcher.refuse(.inputPending)
        #expect(try await !consumer.consume(request(consumer, 0, saying: "Deck, add a slide.")))
        #expect(await consumer.lastRouteRefusal == .notDelivered("Deck"))
        #expect(await consumer.lastDeliveryRefusal == nil)
    }

    /// The privacy gate (#735) comes first: while private every request is held back before any dispatch, so a target
    /// with pending input refuses nothing and nobody is told (no line, no "Nothing was sent.").
    @Test func whilePrivateARequestIsHeldBackSoPendingInputRefusesNothing() async throws {
        let dispatcher = VoiceRouteRecordingDispatcher()
        await dispatcher.refuse(.inputPending)
        let consumer = try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "original", session: session,
                                                allowSynthetic: true, dispatcher: dispatcher,
                                                routing: try Self.voiceRouting(), duckActive: { true })
        _ = try await consumer.consume(start(speakers: "enrolled"))
        #expect(try await !consumer.consume(request(consumer, 0, saying: "What's next?")))
        #expect(await consumer.lastDeliveryRefusal == nil)
        #expect(try await !consumer.consume(request(consumer, 1, saying: "And after that?")))
        #expect(await consumer.lastDeliveryRefusal == nil)
    }
}
