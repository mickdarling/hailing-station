import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectFixRoundTests {
    @Test func confirmationMustNotEraseLaterReassertSendError() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        try await rig.drop()
        let base = ScriptedSocket()
        let held = AmbientHeldPrivacySocket(base: base)
        rig.socket = base
        await rig.connector.enqueue(.socket(held), for: rig.endpoint.url)
        await rig.retry.fire()
        try await rig.handshake(base)
        try await rig.confirmAutomaticSelection()
        try await waitUntil { await held.gate.isWaiting() }
        let old = rig.controller.binding
        try await base.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        #expect(rig.controller.binding == old && rig.controller.reconnect.isPending)
        try rig.discardWhileWaiting()
        #expect(try await audioFrames(base).isEmpty)
        await held.gate.fire()
        try await waitUntil { await held.failed() }
        try await waitUntil { await MainActor.run { !rig.controller.isListening } }
        try await rig.feed()
        #expect(rig.notices.last?.outcome == .failed)
        #expect(rig.unexpected.isEmpty)
        #expect(!rig.controller.isListening, "Reassert send error was ignored after confirmation canceled its waiter")
        #expect(try await audioFrames(base).isEmpty, "PCM sent despite failed privacy reassertion")
        await rig.close()
    }

    @Test func genericRefusalBeforeAcceptanceMustNotEmitAnExtraOrdinaryStopNotice() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        let id = rig.controller.reconnect.notice?.id
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient busy"))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.controller.reconnect.notice?.id == id)
        #expect(rig.notices.last?.outcome == .failed)
        #expect(rig.notices.map(\.id) == [id, id]) // Replaces the same notice; the app deduplicates its haptic.
        #expect(rig.unexpected.isEmpty, "Same drop also emits ordinary onUnexpectedStop after notice replacement")
        await rig.close()
    }

    @Test func transportCloseMustNotDelayDiscardOrStartOfDeadline() async throws {
        let rig = try AmbientReconnectRig()
        let closing = AmbientClosingSocket(base: rig.socket)
        let clock = TestInstantClock()
        rig.transport = closing
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await closing.gate.isWaiting() }
        let before = rig.capture.discardedCount
        for _ in 0..<6 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == before + 6, "Known transport gap admitted capture frames")
        clock.advance(by: .seconds(61))
        #expect(!rig.controller.reconnect.withinDeadline(), "60-second deadline is not armed at transport loss")
        #expect(!rig.controller.isListening)
        await closing.gate.fire()
        try await waitUntil { await rig.retry.isWaiting() }
        try await rig.reconnect()
        await rig.close()
    }
}

private actor AmbientHeldPrivacySocket: WebSocketTransport {
    let base: ScriptedSocket
    let gate = SleepGate()
    private var didFail = false
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        if try FrameCoding.decode(data).payload == .control(.setPrivacy(on: true)) {
            try await gate.sleep(.zero)
            didFail = true
            throw SocketTestError.closed
        }
        await base.send(data)
    }
    func failed() -> Bool { didFail }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}
