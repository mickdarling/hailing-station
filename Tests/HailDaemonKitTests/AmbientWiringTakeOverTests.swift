#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #366 end to end through the listener: a phone streams, a pad takes ambient listening over, the phone's child is
/// retired and the pad gets a fresh one; each device's reply reference (#230) still reaches only that device.
/// Synthetic only (fake `rightyo`, legacy fake adapter); not device hearing.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringTakeOverTests {
    private struct Device {
        let session: URLSession
        let socket: URLSessionWebSocketTask
    }

    /// A negotiated loopback client that gives its device class and can hear `ambient_moved_here`.
    private func connect(
        port: UInt16, kind: String, target: String = LegacyReferenceRig.target
    ) async throws -> Device {
        let (session, socket) = try recipientSocket(port: port)
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [AmbientTakeOver.capability], deviceName: "test", deviceKind: kind
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: target))), on: socket)
        try await recipientSocketBarrier(on: socket)
        return Device(session: session, socket: socket)
    }

    private func segment(_ stream: UUID, _ sequence: Int, final: Bool = false) -> Frame {
        sessionFrame(target: LegacyReferenceRig.target,
                     payload: .audio(ambientSegment(stream: stream, sequence: sequence, isFinal: final)))
    }

    @Test func thePadTakesOverWithAFreshChildAndEachDeviceKeepsItsOwnReplies() async throws {
        let fake = try FakeRightyo(ambientEchoAtEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let rig = try await LegacyReferenceRig.make()
        let events = AmbientEventNames()
        let router = AmbientRightyoRouter(configuration: .init(
            executable: fake.executable, config: fake.config, target: LegacyReferenceRig.target, binding: "binding",
            allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        ), log: { events.record($0) })
        let gate = AmbientAudioGate(target: LegacyReferenceRig.target, sink: router, sweepInterval: nil)
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(ambientAudio: gate), hostName: "mac-test",
            singleTerminalReplyFallback: true, ambient: router
        )
        let port = try await listener.start()
        let phone = try await connect(port: port, kind: "phone")
        let pad = try await connect(port: port, kind: "pad")
        defer {
            for device in [phone, pad] {
                device.socket.cancel(with: .normalClosure, reason: nil)
                device.session.invalidateAndCancel()
            }
        }
        do {
            try await exercise(listener: listener, router: router, rig: rig, phone: phone, pad: pad)
            #expect(events.all.filter { $0 == "ambient_started" }.count == 2)
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private func exercise(
        listener: WebSocketListener, router: AmbientRightyoRouter, rig: LegacyReferenceRig, phone: Device, pad: Device
    ) async throws {
        let phoneStream = UUID(), padStream = UUID()
        for sequence in 0..<2 { try await recipientSocketSend(segment(phoneStream, sequence), on: phone.socket) }
        try await recipientSocketBarrier(on: phone.socket)
        // The pad starts: it is told where listening came from, and the phone's child sees EOF and is retired.
        try await recipientSocketSend(segment(padStream, 0), on: pad.socket)
        #expect(try await recipientSocketReceive(on: pad.socket).payload == .control(.ambientMovedHere(from: "phone")))
        #expect(await eventually { await rig.adapter.deliveries.count == 1 })
        let phoneReference = try #require(blockReference(in: await rig.adapter.deliveries[0].text))
        // The phone's next segment learns that listening moved; it is not an error that ends the connection.
        try await recipientSocketSend(segment(phoneStream, 2), on: phone.socket)
        #expect(try await ambientError(on: phone.socket) == "ambient moved to pad")
        // The phone's earlier request keeps its reference: the reply reaches the phone, not the pad.
        let phoneReply = recipientText(referenceDescriptor(phoneReference))
        #expect(try await listener.publish(phoneReply) == 1)
        #expect(try await recipientSocketReceive(on: phone.socket) == phoneReply)
        try await recipientSocketBarrier(on: pad.socket)
        // The pad's own stream runs in a fresh child; its request and reply belong to the pad.
        try await recipientSocketSend(segment(padStream, 1, final: true), on: pad.socket)
        #expect(await eventually { await rig.adapter.deliveries.count == 2 })
        await router.settle()
        let padReference = try #require(blockReference(in: await rig.adapter.deliveries[1].text))
        #expect(padReference != phoneReference)
        let padReply = recipientText(referenceDescriptor(padReference))
        #expect(try await listener.publish(padReply) == 1)
        #expect(try await recipientSocketReceive(on: pad.socket) == padReply)
        try await recipientSocketBarrier(on: phone.socket)
        try await recipientSocketBarrier(on: pad.socket)
        #expect(router.liveRuns == 0)
    }

    @Test func pingPongBetweenTwoDevicesLeavesOneChildListeningForTheLatest() async throws {
        let fake = try FakeRightyo(ambientEchoAtEOF)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20))
        let phone = try await connect(port: env.port, kind: "phone", target: RecipientTestRig.target)
        let pad = try await connect(port: env.port, kind: "pad", target: RecipientTestRig.target)
        defer {
            for device in [phone, pad] {
                device.socket.cancel(with: .normalClosure, reason: nil)
                device.session.invalidateAndCancel()
            }
        }
        var previous: (device: Device, stream: UUID)?
        for round in 0..<6 {
            let (device, from) = round.isMultiple(of: 2) ? (phone, "pad") : (pad, "phone")
            let stream = UUID()
            try await recipientSocketSend(audio(stream, 0), on: device.socket)
            if round > 0 {
                #expect(try await recipientSocketReceive(on: device.socket).payload
                    == .control(.ambientMovedHere(from: from)))
            }
            try await recipientSocketBarrier(on: device.socket)
            if let previous {
                try await recipientSocketSend(audio(previous.stream, 1), on: previous.device.socket)
                #expect(try await ambientError(on: previous.device.socket).hasPrefix("ambient moved to "))
            }
            #expect(await env.gate.activeStream == stream)
            // Each retired child is reaped before the next swap, so the live-child bound is never the limit.
            #expect(await eventually { env.router.liveRuns == 1 })
            previous = (device, stream)
        }
        await env.listener.stop(reason: "synthetic test complete")
        #expect(env.router.liveRuns == 0)
    }
}
#endif
