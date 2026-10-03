import Foundation
import Testing
@testable import HailDaemonKit

/// Records what the consumer hands to the final delivery step, or refuses it (#188 item 1, part B).
actor RecordingDispatcher: RightyoDispatching {
    struct Call: Equatable {
        var text: String
        var target: String
        var binding: String
    }

    private(set) var calls: [Call] = []
    private let receipt: RightyoDispatchReceipt
    private let refusal: (any Error)?

    init(receipt: RightyoDispatchReceipt = .init(request: nil), refusal: (any Error)? = nil) {
        self.receipt = receipt
        self.refusal = refusal
    }

    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        calls.append(Call(text: text, target: target, binding: binding))
        if let refusal { throw refusal }
        return receipt
    }
}

/// The injectable delivery step: validation and correlation stay in front of it, only delivery differs.
extension RightyoInputConsumerTests {
    func dispatching(
        _ dispatcher: RecordingDispatcher, allowSynthetic: Bool = true
    ) throws -> RightyoInputConsumer {
        try RightyoInputConsumer(host: nil, target: "tmux:demo", binding: "pinned", session: session,
                                 allowSynthetic: allowSynthetic, dispatcher: dispatcher)
    }

    @Test func dispatcherReceivesExactlyThePromptTargetAndPinnedBinding() async throws {
        let owner = UUID()
        let dispatcher = RecordingDispatcher(receipt: .init(request: owner))
        let consumer = try dispatching(dispatcher)
        #expect(try await !consumer.consume(start()))
        let prior = turn("earlier", start: 100, end: 900)
        let attended = try await preparedRequest(consumer, turns: [prior])
        #expect(try await consumer.consume(attended))
        #expect(await consumer.lastReceipt == RightyoDispatchReceipt(request: owner))
        // The duplicate is ignored before the delivery step and clears the receipt of the earlier event.
        #expect(try await !consumer.consume(attended))
        #expect(await consumer.lastReceipt == nil)
        let calls = await dispatcher.calls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.target == "tmux:demo")
        #expect(call.binding == "pinned")
        // Same prompt the direct path delivers: the direct rig consumes the same events through a real host.
        let (direct, adapter) = try await rig()
        _ = try await direct.consume(start())
        #expect(try await direct.consume(preparedRequest(direct, turns: [prior])))
        #expect(await adapter.deliveries.map(\.text) == [call.text])
        #expect(await adapter.deliveries.first?.binding == "original")
        #expect(await direct.lastReceipt == RightyoDispatchReceipt(request: nil))
    }

    @Test func dispatcherRefusalIsTerminalAndNeverRetried() async throws {
        let dispatcher = RecordingDispatcher(refusal: RightyoInputError.confirmationRequired)
        let consumer = try dispatching(dispatcher)
        _ = try await consumer.consume(start())
        let attended = try await preparedRequest(consumer)
        await #expect(throws: RightyoInputError.confirmationRequired) { try await consumer.consume(attended) }
        #expect(await consumer.lastReceipt == nil)
        #expect(try await !consumer.consume(attended))
        await #expect(throws: RightyoInputError.invalidLifecycle) {
            try await consumer.consume(event("session", sequence: 9, extra: ["phase": "stopped"]))
        }
        await #expect(throws: RightyoInputError.producerFailed) { try await consumer.finish() }
        #expect(await dispatcher.calls.count == 1)
    }

    @Test func nullOwnershipReceiptIsDeliveredNotRefused() async throws {
        let dispatcher = RecordingDispatcher(receipt: .init(request: nil, caveat: "handed off, but no owner"))
        let consumer = try dispatching(dispatcher)
        _ = try await consumer.consume(start())
        #expect(try await consumer.consume(preparedRequest(consumer)))
        let receipt = try #require(await consumer.lastReceipt)
        #expect(receipt.request == nil)
        #expect(receipt.caveat == "handed off, but no owner")
        _ = try await consumer.consume(event("session", sequence: 9, extra: ["phase": "stopped"]))
        try await consumer.finish()
        #expect(await dispatcher.calls.count == 1)
    }

    @Test func provenanceRuleStillGatesTheDispatcher() async throws {
        let dispatcher = RecordingDispatcher(receipt: .init(request: UUID()))
        let consumer = try dispatching(dispatcher, allowSynthetic: false)
        _ = try await consumer.consume(start())
        let attended = try await preparedRequest(consumer)
        await #expect(throws: RightyoInputError.invalidEvent) { try await consumer.consume(attended) }
        #expect(await dispatcher.calls.isEmpty)
        #expect(await consumer.lastReceipt == nil)
    }

    @Test func hostDispatcherCancelsConfirmationAndMintsNoOwnership() async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "demo", binding: "original")])
        let open = RightyoHostDispatcher(host: try await HostSendTests().host(adapter))
        let receipt = try await open.dispatch(text: "hello", target: "tmux:demo", binding: "original")
        #expect(receipt == RightyoDispatchReceipt(request: nil))
        #expect(await adapter.deliveries.map(\.text) == ["hello"])
        await #expect(throws: HostError.denied(.rebound("tmux:demo"))) {
            try await open.dispatch(text: "hello", target: "tmux:demo", binding: "replacement")
        }
        let confirm = RightyoHostDispatcher(host: try await HostSendTests().host(adapter, tier: .confirm))
        await #expect(throws: RightyoInputError.confirmationRequired) {
            try await confirm.dispatch(text: "hello again", target: "tmux:demo", binding: "original")
        }
        #expect(await adapter.deliveries.count == 1)
    }
}
