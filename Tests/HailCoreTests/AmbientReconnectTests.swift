import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #904 ask 3. Scripted sockets and synthetic capture only; no iOS background/haptic proof.
@MainActor
@Suite(.serialized) struct AmbientReconnectTests {
    @Test func sameEndpointAndTargetRestoreWithOneNoticeAndFreshCapture() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let old = try rig.currentBinding()
        try await rig.drop()
        #expect(rig.controller.reconnect.wantsListening)
        try await rig.reconnect()
        #expect(rig.controller.isListening)
        #expect(rig.capture.startCount == 2)
        #expect(rig.permissionCalls == 2)
        #expect(rig.controller.binding != old)
        #expect(rig.notices.map(\.outcome) == [.applied])
        #expect(rig.notices[0].text.contains("listening resumed"))
        await rig.close()
    }

    @Test func offStaysOffWithoutANoticeBecauseListeningWasUnaffected() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        try await rig.drop()
        try await rig.reconnect()
        #expect(!rig.controller.isOn)
        #expect(rig.capture.startCount == 0)
        #expect(rig.notices.isEmpty)
        await rig.close()
    }

    @Test func ownerStopDuringGapBlocksRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        await rig.controller.turnOff()
        try await rig.reconnect()
        try await rig.expectStopped(.ownerStop)
        await rig.close()
    }

    @Test(arguments: [true, false]) func eitherPrivacySwitchDirectionBlocksRestore(on: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try? await rig.store.setPrivacy(on: on, host: rig.endpoint.id)
        try await rig.reconnect()
        try await rig.expectStopped(.privacy)
        await rig.close()
    }

    @Test func ownerTargetSwitchDuringGapBlocksRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try? await rig.store.selectTarget(host: rig.endpoint.id, targetID: "tmux:other")
        try await rig.reconnect()
        try await rig.expectStopped(.ownerSelection)
        await rig.close()
    }

    @Test(arguments: [true, false]) func endpointRemovalOrReplacementBlocksRestore(remove: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        if remove { await rig.store.remove(rig.endpoint.id) }
        var replacement = rig.endpoint
        replacement.name = "Replacement"
        await rig.store.upsert(replacement)
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: replacement.url)
        await rig.store.connect(replacement.id)
        await rig.retry.fire()
        try await rig.handshake(rig.socket)
        try await rig.expectStopped(.endpointChanged)
        await rig.close()
    }

    @Test(arguments: [ControlPayload.duckMode(on: true), .mediaMode(on: true)])
    func hostPrivateOrMediaModeOnReconnectBlocksRestore(mode: ControlPayload) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(mode: mode)
        let reason: AmbientListeningReconnect.Reason = mode == .duckMode(on: true) ? .privacy : .modeChanged
        try await rig.expectStopped(reason)
        await rig.close()
    }

    @Test func explicitDisconnectNeverArmsRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        await rig.store.disconnect(rig.endpoint.id)
        await rig.controller.update(binding: nil, scene: .active)
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await rig.store.connect(rig.endpoint.id)
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: true)
        #expect(!rig.controller.isOn)
        #expect(rig.capture.startCount == 1)
        #expect(rig.notices.isEmpty)
        await rig.close()
    }

    @Test(arguments: [true, false]) func failedStartOrPermissionDenialIsOneAttempt(failCapture: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        rig.failStart = failCapture
        rig.permission = failCapture
        try await rig.reconnect()
        #expect(!rig.controller.isOn)
        #expect(rig.notices.map(\.outcome) == [.failed])
        #expect(rig.notices[0].text.contains("tap to resume"))
        for _ in 0..<3 {
            await rig.controller.reconnect.restore(controller: rig.controller, store: rig.store)
            await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        }
        #expect(rig.permissionCalls == 2)
        #expect(rig.capture.startCount == 1)
        #expect(rig.notices.count == 1)
        await rig.close()
    }

    @Test func twoConsecutiveDropsEachRestoreAndNotifyOnce() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        for _ in 0..<2 { try await rig.drop(); try await rig.reconnect() }
        #expect(rig.capture.startCount == 3)
        #expect(rig.notices.map(\.outcome) == [.applied, .applied])
        await rig.close()
    }

}

extension AmbientReconnectTests {
    @Test func differentEndpointCannotRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let other = try endpoint("mac-2", "ws://127.0.0.1:8766")
        await rig.store.upsert(other)
        try? await rig.store.selectTarget(host: other.id, targetID: rig.target.id)
        let socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(socket), for: other.url)
        await rig.store.connect(other.id)
        try await waitUntil { try await socket.sentFrames().count == 1 }
        try await socket.push(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["ping", "select_target", "stream_audio"],
            deviceName: "Synthetic"
        )))
        try await socket.push(.targets([rig.target]))
        try await waitUntil { await MainActor.run {
            rig.store.snapshots[other.id]?.receivedTargetList == true
        } }
        let selection = Task { try await rig.store.selectTarget(host: other.id, targetID: rig.target.id) }
        try await waitUntil { try await socket.sentFrames().count { if case .control(.ping) = $0.payload {
            return true
        }; return false } == 2 }
        let pings = try await socket.sentFrames().compactMap { frame -> String? in
            if case .control(.ping(let nonce)) = frame.payload { return nonce }; return nil
        }
        for ping in pings { try await socket.push(.pong(nonce: ping)) }
        try await selection.value
        try await rig.expectStopped(.ownerSelection)
        await rig.store.disconnect(other.id)
        await rig.close()
    }
}
