#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Runs `body` against a started listener with `count` loopback devices all selecting the legacy target.
private func withDevices(
    _ count: Int,
    _ body: (LegacyReferenceRig, WebSocketListener, RoutedReplyEvents, FallbackSocketPair) async throws -> Void
) async throws {
    let rig = try await LegacyReferenceRig.make()
    let (listener, events) = try rig.routedListener()
    let port = try await listener.start()
    let devices = try await FallbackSocketPair.connect(
        port: port, selecting: Array(repeating: LegacyReferenceRig.target, count: count)
    )
    defer { devices.close() }
    do {
        try await body(rig, listener, events, devices)
    } catch {
        await listener.stop(reason: "synthetic test failed")
        throw error
    }
    await listener.stop(reason: "synthetic test complete")
}

/// Ambient input from device `index`: the daemon's own ambient delivery step on behalf of that connection.
private func ambient(
    from index: Int, _ listener: WebSocketListener, _ events: RoutedReplyEvents
) async throws -> UUID? {
    let connection = try await listener.sessionConnection(of: events.connected[index])
    return try await ambientDispatch(listener, LegacyReferenceRig.request(connection: connection))
}

/// A request-less reply (text, then streamed speech) reaches device `index` only.
private func expectReply(
    to index: Int, _ listener: WebSocketListener, _ devices: FallbackSocketPair
) async throws {
    let reply = referenceDescriptor(nil, audio: true)
    for frame in [recipientText(reply), recipientAudio(reply, sequence: 0),
                  recipientAudio(reply, sequence: 1, final: true)] {
        #expect(try await listener.publish(frame) == 1)
        #expect(try await recipientSocketReceive(on: devices.sockets[index]) == frame)
    }
    try await devices.barrier()
}

/// #370 over loopback sockets: two devices select the same plain tmux target. A reply without a request reference
/// goes to the device that last sent that target input, by tap-to-talk or ambient. Synthetic only; not device hearing.
@Suite(.serialized) struct LastInputReplyRoutingTests {
    @Test func tapToTalkThenAmbientThenAlternatingEachReplyGoesOnlyToTheLastInputDevice() async throws {
        try await withDevices(2) { rig, listener, events, devices in
            try await devices.tap(on: 1, rig: rig)
            // No footer, reference or instruction is added to typed text.
            #expect(await rig.adapter.deliveries.last?.text == "synthetic tap")
            try await expectReply(to: 1, listener, devices)
            _ = try await ambient(from: 0, listener, events)
            try await expectReply(to: 0, listener, devices)
            _ = try await ambient(from: 1, listener, events)
            try await expectReply(to: 1, listener, devices)
            try await devices.tap(on: 0, rig: rig)
            try await expectReply(to: 0, listener, devices)
            // One audit event per reply, naming the path and only the connection id already logged at connect.
            let expected = [1, 0, 1, 0].map { events.connected[$0] }
            #expect(events.routes.map(\.0) == expected)
            #expect(events.routes.allSatisfy { $0.1 == "path=last_input" })
        }
    }

    @Test func aReplyThatStartedOnOneDeviceNeverMovesToTheNextInputDevice() async throws {
        try await withDevices(2) { rig, listener, events, devices in
            try await devices.tap(on: 1, rig: rig)
            let reply = referenceDescriptor(nil, audio: true)
            let text = recipientText(reply)
            #expect(try await listener.publish(text) == 1)
            #expect(try await recipientSocketReceive(on: devices.sockets[1]) == text)
            // Device 0 speaks while the first reply is still streaming: the rest of it stays on device 1.
            _ = try await ambient(from: 0, listener, events)
            let rest = recipientAudio(reply, sequence: 0, final: true)
            #expect(try await listener.publish(rest) == 1)
            #expect(try await recipientSocketReceive(on: devices.sockets[1]) == rest)
            try await devices.barrier()
            // A new reply follows the new last input device.
            try await expectReply(to: 0, listener, devices)
            #expect(events.routes.map(\.1) == ["path=last_input", "path=last_input"])
            // Once its device selects away, a pinned reply is refused rather than moved.
            try await devices.select(LegacyReferenceRig.other, on: 1)
            await #expect(throws: LocalReplyRefusal.noRecipient) {
                try await listener.publish(recipientAudio(reply, sequence: 1, final: true))
            }
            try await devices.barrier()
        }
    }

    @Test func aRequestReferenceStillWinsOverTheLastInputDevice() async throws {
        try await withDevices(2) { rig, listener, events, devices in
            let owner = try #require(try await ambient(from: 0, listener, events))
            try await devices.tap(on: 1, rig: rig)
            let referenced = recipientText(referenceDescriptor(owner))
            #expect(try await listener.publish(referenced) == 1)
            #expect(try await recipientSocketReceive(on: devices.sockets[0]) == referenced)
            try await devices.barrier()
            try await expectReply(to: 1, listener, devices)
            #expect(events.routes.map(\.1) == ["path=request", "path=last_input"])
        }
    }

    @Test func aDisconnectedLastInputDeviceFallsBackToTheSingleSelectorRule() async throws {
        try await withDevices(3) { rig, listener, events, devices in
            try await devices.tap(on: 0, rig: rig)
            devices.sockets[0].cancel(with: .normalClosure, reason: nil)
            #expect(await eventually { await listener.peers.count == 2 })
            // Two devices still select the target and neither sent input: today's refusal, not a guess.
            await #expect(throws: LocalReplyRefusal.notUniqueRecipient) {
                try await listener.publish(recipientText(referenceDescriptor(nil)))
            }
            // With one selector left, the single-selector rule delivers to it.
            try await devices.select(LegacyReferenceRig.other, on: 2)
            let sole = recipientText(referenceDescriptor(nil))
            #expect(try await listener.publish(sole) == 1)
            #expect(try await recipientSocketReceive(on: devices.sockets[1]) == sole)
            for index in [1, 2] { try await recipientSocketBarrier(on: devices.sockets[index]) }
            #expect(events.routes.map(\.1) == ["path=single_selector"])
        }
    }

    @Test func aMovedSelectionFallsBackEvenWhenTheDeviceReturnsToTheTarget() async throws {
        try await withDevices(2) { rig, listener, _, devices in
            try await devices.tap(on: 0, rig: rig)
            // Away and back is a new selection generation: the old input no longer routes.
            try await devices.select(LegacyReferenceRig.other, on: 0)
            try await devices.select(LegacyReferenceRig.target, on: 0)
            await #expect(throws: LocalReplyRefusal.notUniqueRecipient) {
                try await listener.publish(recipientText(referenceDescriptor(nil)))
            }
            // Away for good: the other device is the only selector.
            try await devices.select(LegacyReferenceRig.other, on: 0)
            try await expectReply(to: 1, listener, devices)
        }
    }

    @Test func contextualAdaptersKeepTheirCorrelatedRoutingAndUnalteredText() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: true)
        let port = try await listener.start()
        let devices = try await FallbackSocketPair.connect(
            port: port, selecting: [RecipientTestRig.target, RecipientTestRig.target]
        )
        defer { devices.close() }
        do {
            let first = try await devices.submitInput(on: 0, rig: rig)
            _ = try await devices.submitInput(on: 1, rig: rig)
            // A correlated reply still reaches its owner, though device 1 spoke last.
            let correlated = recipientText(recipientDescriptor(first))
            #expect(try await listener.publish(correlated) == 1)
            #expect(try await recipientSocketReceive(on: devices.sockets[0]) == correlated)
            // A request-less one follows the last input device.
            let requestless = recipientText(uncorrelatedDescriptor())
            #expect(try await listener.publish(requestless) == 1)
            #expect(try await recipientSocketReceive(on: devices.sockets[1]) == requestless)
            try await devices.barrier()
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }
}
#endif
