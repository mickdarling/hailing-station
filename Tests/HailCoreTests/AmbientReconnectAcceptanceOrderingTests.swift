import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAcceptanceOrderingTests {
    @Test(arguments: [true, false])
    func orderedRefusalAfterPongUsesOrdinaryStopWhileConfirmationSendIsHeld(moved: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let wire = AmbientAcceptanceTestWire(base: ScriptedSocket())
        try await restore(rig, wire: wire)
        let proof = try #require(rig.controller.reconnect.acceptance)
        try await waitUntil { await wire.isHeld() }
        let id = rig.controller.reconnect.notice?.id
        // One actor operation queues both frames, while confirmRoundTrip's send remains suspended.
        try await wire.deliver([
            .pong(nonce: proof.nonce),
            .error(code: .notAllowed, message: moved ? "ambient moved to pad" : "ambient busy elsewhere")
        ])
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(await wire.isHeld())
        #expect(rig.controller.reconnect.acceptance == nil)
        #expect(rig.notices.map(\.id) == [id])
        #expect(rig.notices.last?.outcome == .applied)
        #expect(!rig.controller.reconnect.replacedAppliedNotice)
        if moved {
            #expect(rig.controller.handoff == .movedAway(to: "pad") && rig.unexpected.isEmpty)
        } else {
            #expect(rig.unexpected.count == 1 && rig.unexpected[0].contains("ambient busy elsewhere"))
        }
        await wire.release()
        await rig.close()
    }

    @Test func terminalRefusalOfRenewedStreamCannotRewriteUnacceptedRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let wire = AmbientAcceptanceTestWire(base: ScriptedSocket())
        try await restore(rig, wire: wire)
        let proof = try #require(rig.controller.reconnect.acceptance)
        try await waitUntil { await wire.isHeld() }
        let id = rig.controller.reconnect.notice?.id
        try await wire.deliver([.error(code: .notAllowed, message: "ambient stopped: listener exited")])
        try await waitUntil { await wire.transientWasProcessed() }
        try await rig.feed() // The next segment observes the stored transient refusal and begins #287's backoff.
        try await waitUntil(timeout: .seconds(8)) {
            try await MainActor.run {
                for index in 0..<6 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
            }
            return try await audioFrames(rig.socket).contains { frame in
                if case .audio(let audio) = frame.payload {
                    return audio.isResume && audio.sequence == 0 && audio.streamID != proof.streamID
                }
                return false
            }
        }
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        #expect(rig.controller.reconnect.acceptance === proof) // Still no pong for the restore's own ping.
        try await wire.deliver([.error(code: .notAllowed, message: "ambient busy elsewhere")])
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.map(\.id) == [id])
        #expect(rig.notices.last?.outcome == .applied && !rig.controller.reconnect.replacedAppliedNotice)
        #expect(rig.unexpected.count == 1 && rig.unexpected[0].contains("ambient busy elsewhere"))
        await wire.release()
        await rig.close()
    }

    @Test func unrelatedPongCannotAcceptRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let wire = AmbientAcceptanceTestWire(base: ScriptedSocket())
        try await restore(rig, wire: wire)
        let proof = try #require(rig.controller.reconnect.acceptance)
        try await waitUntil { await wire.isHeld() }
        let frames = try await rig.socket.sentFrames()
        let otherNonce = try #require(frames.compactMap { frame -> String? in
            if case .control(.ping(let nonce)) = frame.payload, nonce != proof.nonce { return nonce }
            return nil
        }.first)
        let id = rig.controller.reconnect.notice?.id
        try await wire.deliver([
            .pong(nonce: otherNonce), .error(code: .notAllowed, message: "ambient busy elsewhere")
        ])
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.map(\.id) == [id, id])
        #expect(rig.notices.last?.outcome == .failed && rig.controller.reconnect.replacedAppliedNotice)
        #expect(rig.unexpected.isEmpty)
        await wire.release()
        await rig.close()
    }

    @Test func stalePongOnReplacementCannotAcceptNewRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let first = AmbientAcceptanceTestWire(base: ScriptedSocket())
        try await restore(rig, wire: first)
        let retired = try #require(rig.controller.reconnect.acceptance)
        try await waitUntil { await first.isHeld() }
        try await rig.drop()
        #expect(rig.controller.reconnect.acceptance == nil)
        let second = AmbientAcceptanceTestWire(base: ScriptedSocket())
        rig.socket = second.base
        await rig.connector.enqueue(.socket(second), for: rig.endpoint.url)
        await rig.retry.fire()
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await rig.feed()
        let current = try #require(rig.controller.reconnect.acceptance)
        #expect(current.binding.connectionGeneration != retired.binding.connectionGeneration)
        let id = rig.controller.reconnect.notice?.id
        try await waitUntil { await second.isHeld() }
        try await second.deliver([
            .pong(nonce: retired.nonce), .error(code: .notAllowed, message: "ambient busy elsewhere")
        ])
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.map(\.outcome) == [.applied, .applied, .failed])
        #expect(rig.notices.last?.id == id && rig.controller.reconnect.replacedAppliedNotice)
        #expect(rig.unexpected.isEmpty)
        await second.release()
        await rig.close()
    }

    @Test func sendErrorBeforeMatchingPongRevisesSameNotice() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let wire = AmbientAcceptanceTestWire(base: ScriptedSocket())
        try await restore(rig, wire: wire)
        try await waitUntil { await wire.isHeld() }
        let id = rig.controller.reconnect.notice?.id
        await wire.refuseAudio()
        try await rig.feed()
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.map(\.id) == [id, id])
        #expect(rig.notices.last?.outcome == .failed && rig.controller.reconnect.replacedAppliedNotice)
        #expect(rig.unexpected.isEmpty)
        await wire.release()
        await rig.close()
    }

    private func restore(_ rig: AmbientReconnectRig, wire: AmbientAcceptanceTestWire) async throws {
        rig.socket = wire.base
        await rig.connector.enqueue(.socket(wire), for: rig.endpoint.url)
        await rig.retry.fire()
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
    }
}
