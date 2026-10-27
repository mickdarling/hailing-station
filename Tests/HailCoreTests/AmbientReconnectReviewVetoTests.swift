import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReviewVetoTests {
    @Test func failedOwnerPrivacyTapMustNotBeClearedByAnotherHostsConfirmation() async throws {
        let rig = try AmbientReconnectRig()
        rig.transport = AmbientFailingPrivacySocket(base: rig.socket)
        try await rig.start()
        do {
            try await rig.store.setPrivacy(on: false, host: rig.endpoint.id)
            Issue.record("The owner's privacy send must fail while the link is healthy")
        } catch { #expect(error as? HostConnectionFailure == .remote("synthetic privacy refusal")) }
        #expect(rig.store.privacyLocal[rig.endpoint.id]?.request == nil)
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
        #expect(rig.controller.isListening && !rig.controller.reconnect.isPending && rig.notices.isEmpty)
        let other = try await confirmOtherHostPrivacy(rig)
        #expect(rig.controller.isListening && !rig.controller.reconnect.isPending && rig.notices.isEmpty)
        try await rig.drop()
        try await rig.reconnect()
        #expect(rig.notices.last?.reason == .privacy,
                "Another host's confirmation cleared the failed owner-tap veto without an owner start")
        #expect(!rig.controller.isListening)
        let frames = try await rig.socket.sentFrames()
        #expect(frames.allSatisfy { if case .audio = $0.payload { return false }; return true },
                "Resumed PCM reached the replacement host after the failed owner tap")
        if rig.controller.isOn { await rig.controller.turnOff() } // Let a mutant reach the owner-start tail too.
        try await waitUntil { await MainActor.run { !rig.controller.isOn } }
        await rig.controller.turnOn(for: try rig.currentBinding()) // An owner start alone clears the veto.
        try await rig.drop()
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.blocked, .applied])
        await rig.close()
        await rig.store.disconnect(other.id)
    }

    @Test func secondDropBeforeFirstResumedPCMStillMustDiscardAtCapture() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.select(restoring: true)
        #expect(rig.controller.reconnect.isPending && rig.notices.isEmpty)
        let newBinding = rig.controller.binding
        #expect(newBinding == (try rig.currentBinding()))
        try await rig.drop()
        let before = rig.capture.discardedCount
        for _ in 0..<10 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == before + 10,
                "Second transport gap accepted microphone frames into the capture stream")
        await rig.close()
    }

    private func confirmOtherHostPrivacy(_ rig: AmbientReconnectRig) async throws -> HostEndpoint {
        let other = try endpoint("other", "ws://127.0.0.1:8766")
        let otherSocket = ScriptedSocket()
        await rig.connector.enqueue(.socket(otherSocket), for: other.url)
        await rig.store.upsert(other)
        await rig.store.connect(other.id)
        try await waitUntil { try await otherSocket.sentFrames().contains { if case .control(.hello) = $0.payload {
            return true
        }; return false } }
        try await otherSocket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
            capabilities: ["ping", "set_privacy"], deviceName: "Synthetic")))
        try await waitUntil { await MainActor.run { rig.store.snapshots[other.id]?.state == .ready } }
        try await rig.store.setPrivacy(on: false, host: other.id)
        try await otherSocket.push(.duckMode(on: false, reason: "device"))
        try await waitUntil { await MainActor.run {
            rig.store.privacyLocal[other.id]?.request == nil && rig.store.duckMode[other.id]?.on == false
        } }
        return other
    }
}

/// Refuse only the control send: the receive loop and active capture stay healthy until the explicit drop.
private actor AmbientFailingPrivacySocket: WebSocketTransport {
    let base: ScriptedSocket
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        if try FrameCoding.decode(data).payload == .control(.setPrivacy(on: false)) {
            throw HostConnectionFailure.remote("synthetic privacy refusal")
        }
        await base.send(data)
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}
