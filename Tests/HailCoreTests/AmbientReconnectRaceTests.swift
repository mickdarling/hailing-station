import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectRaceTests {
    /// Port of the reviewer's failing privacy repro; both switch directions veto even after the failed send clears it.
    @Test(arguments: [true, false]) func privacyTapBeforeDropPublicationMustBlock(on: Bool) async throws {
        let rig = try AmbientReconnectRig()
        let closing = AmbientClosingSocket(base: rig.socket)
        rig.transport = closing
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await closing.gate.isWaiting() }
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
        #expect(rig.controller.reconnect.isPending) // Loss is now reported before reconnecting is published.
        try? await rig.store.setPrivacy(on: on, host: rig.endpoint.id)
        #expect(rig.store.privacyLocal[rig.endpoint.id]?.request == nil)
        await closing.gate.fire()
        try await waitUntil { await rig.retry.isWaiting() }
        try await rig.expectStopped(.privacy)
        try await rig.reconnect()
        #expect(rig.notices.count == 1)
        await rig.close()
    }
    @Test func audioSeesTransportCloseBeforeReceiveLoopPublishesIt() async throws {
        let rig = try AmbientReconnectRig()
        let closing = AmbientClosingSocket(base: rig.socket)
        rig.transport = closing
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await closing.gate.isWaiting() }
        for index in 0..<3 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await MainActor.run { rig.controller.reconnect.isPending } }
        rig.controller.reconnect.restore(store: rig.store)
        #expect(rig.notices.isEmpty && rig.capture.startCount == 1)
        await closing.gate.fire()
        try await waitUntil { await rig.retry.isWaiting() }
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }
    /// Port of review repro 2, amended by host-admission decision 2 and #945: unknown may restore; late host
    /// privacy/media acts just like normal listening. In particular `device` is NOT a new owner tap during the gap.
    @Test(arguments: [ControlPayload.duckMode(on: true, reason: "device"), .mediaMode(on: true)])
    func unknownModesRestoreAndLateHostNoticeActsNormally(mode: ControlPayload) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        #expect(rig.controller.reconnect.isPending) // Fresh first send still pending, after capture's gate reopened.
        try await rig.socket.push(mode)
        let privacy = mode != .mediaMode(on: true)
        try await waitUntil { await MainActor.run {
            privacy ? rig.store.duckMode[rig.endpoint.id]?.on == true : rig.store.mediaMode[rig.endpoint.id]?.on == true
        } }
        #expect(rig.controller.isListening)
        if privacy { #expect(rig.store.privacySwitch(rig.endpoint.id).isPrivate) }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount == 0)
        await rig.close()
    }
    @Test func resumeRefusalShowsMovedAwayAndReleasesCaptureWithoutLoopOrError() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        rig.wrapReconnect = { AmbientMovedSocket(base: $0) }
        try await rig.reconnect()
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.controller.handoff == .movedAway(to: "pad"))
        #expect(rig.unexpected.isEmpty && rig.released == 1)
        #expect(rig.notices.count == 1 && rig.notices.last?.reason == .movedAway)
        #expect(rig.capture.startCount == 1)
        await rig.close()
    }
    @Test(arguments: ["not_allowed: ambient busy", "not_allowed: ambient stopped: listener exited"])
    func refusedAdmissionStopsWithOneNoticeWithoutOrdinaryStopSpamOrRetry(message: String) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        rig.wrapReconnect = { AmbientMovedSocket(base: $0, message: message) }
        try await rig.reconnect()
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.count == 1 && rig.notices.last?.outcome == .failed)
        #expect(rig.unexpected.isEmpty && rig.released == 1 && rig.capture.startCount == 1)
        await rig.close()
    }
    @Test func deadlineAlsoWinsIfItsTaskHasNotBeenScheduled() async throws {
        let rig = try AmbientReconnectRig()
        let clock = TestInstantClock()
        rig.controller.reconnect.now = { clock.now() }
        try await rig.start()
        try await rig.drop()
        clock.advance(by: .seconds(60))
        try await rig.reconnect()
        try await rig.expectStopped(.timedOut)
        await rig.close()
    }
}

actor AmbientClosingSocket: WebSocketTransport {
    let base: ScriptedSocket
    let gate = SleepGate()
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws { await base.send(data) }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { try? await gate.sleep(.zero); await base.close() }
}

/// The host gate's moved-away refusal is final, and only a `resume` is offered. The real gate counterpart is
/// AmbientResumeGateTests.aRetryAfterAnotherDeviceStartedIsToldListeningMovedAndTakesNothing.
private actor AmbientMovedSocket: WebSocketTransport {
    let base: ScriptedSocket
    let message: String
    init(base: ScriptedSocket, message: String = "not_allowed: ambient moved to pad") {
        self.base = base
        self.message = message
    }
    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        if case .audio(let audio) = frame.payload {
            #expect(audio.sequence == 0 && audio.isResume)
            throw HostConnectionFailure.remote(message)
        }
        await base.send(data)
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}
