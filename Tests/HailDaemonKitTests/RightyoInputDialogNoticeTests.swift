import Foundation
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

#if os(macOS)
extension RightyoInputConsumerTests {
    @Test(arguments: [0, 2])
    func cancelledDialogDispatchHasNoPerRequestRefusalNoticeOrClip(_ earlier: Int) async throws {
        let run = try await PendingInputRun.make(options: .init(holdFirst: true))
        defer { run.close() }
        let block = DialogBlock(cause: .known(.modalFooter), effects: .none)
        let error: any Error = earlier == 0 ? AdapterError.blockedByDialog(block)
            : HostError.partial(delivered: Array(repeating: "synthetic private line", count: earlier),
                                reason: .dialog(block))
        await run.adapter.failHandoff(with: error)
        await run.adapter.holdHandoff()
        let connection = try #require(await run.connection)
        let notices = AmbientRefusalNotices()
        let peer = try #require(await run.env.listener.peers.values.first)
        let dispatcher = AmbientListenerDispatcher(listener: run.env.listener, audit: nil,
                                                   selection: await peer.session.selectionGeneration,
                                                   refusalNotices: notices)
        let step = RightyoAmbientDispatchStep(connection: connection, dispatcher: dispatcher)
        let consumer = try RightyoInputConsumer(host: nil, target: RecipientTestRig.target, binding: "reply-binding",
                                                session: session, allowSynthetic: true, dispatcher: step)
        _ = try await consumer.consume(start(speakers: "enrolled"))
        let event = try await request(consumer, 0, saying: "synthetic request")
        let dispatch = Task { try await consumer.consume(event) }
        await run.adapter.waitForHandoff()
        dispatch.cancel()
        await run.adapter.releaseHandoff()
        await #expect(throws: CancellationError.self) { try await dispatch.value }
        #expect(await consumer.lastDeliveryRefusal == nil)
        #expect(await consumer.lastRouteRefusal == nil)
        #expect(await consumer.lastReceipt == nil)
        #expect(await consumer.requestRefusal == nil)
        #expect(notices.takeDialogTarget() == nil)
        #expect(run.queued.count(for: connection) == 0)
        #expect(run.log.details("ambient_delivery_refused").isEmpty)
        try await barrier(on: run.socket, step: "cancelled dialog has no notice or clip frames")
        await run.finish()
    }
}
#endif
