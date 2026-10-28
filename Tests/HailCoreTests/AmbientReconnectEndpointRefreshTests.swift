import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectEndpointRefreshTests {
    @Test(arguments: [false, true], [false, true])
    func endpointReplacementRestoresAndReconfirmsTheRetainedDestination(isPrivate: Bool, newURL: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        if isPrivate { try await rig.confirmInitialPrivacy() }
        let old = try rig.currentBinding()
        try await rig.drop()
        var refreshed = rig.endpoint
        if newURL { refreshed.url = try #require(URL(string: "ws://127.0.0.1:18765")) }
        refreshed.name = "Refreshed synthetic host"
        try await replace(rig, endpoint: refreshed)
        #expect(rig.store.ambientBinding(host: refreshed.id, targetID: rig.target.id) == nil)
        #expect(try await audioFrames(rig.socket).isEmpty)
        try await rig.select(restoring: true)
        if isPrivate { try await confirmRefreshPrivacy(rig) }
        try await rig.feed()
        let current = try rig.currentBinding()
        #expect(current.selection == old.selection && current.connectionGeneration != old.connectionGeneration)
        let frames = try await rig.socket.sentFrames()
        #expect(frames.compactMap { frame -> String? in
            if case .control(.select(let target)) = frame.payload { return target }; return nil
        } == [rig.target.id])
        let resumed = try #require(try await audioFrames(rig.socket).first)
        if case .audio(let audio) = resumed.payload { #expect(audio.sequence == 0 && audio.isResume) }
        #expect(resumed.target == rig.target.id && rig.controller.isListening && rig.capture.startCount == 1)
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }

    @Test func activeEndpointRefreshKeepsTheRetainedCapture() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        var refreshed = rig.endpoint
        refreshed.name = "Updated synthetic name"
        try await replace(rig, endpoint: refreshed)
        try await rig.select(restoring: true)
        try await rig.feed()
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }

    @Test func secureTransportDowngradeVetoesRefresh() async throws {
        let rig = try AmbientReconnectRig()
        var secure = rig.endpoint
        secure.url = try #require(URL(string: "wss://127.0.0.1:18765"))
        await rig.store.upsert(secure)
        await rig.connector.enqueue(.socket(rig.socket), for: secure.url)
        await rig.store.connect(secure.id)
        rig.store.ambientController = rig.controller
        rig.controller.reconnect.onNotice = { [weak rig] in rig?.notices.append($0) }
        try await rig.handshake(rig.socket)
        try await rig.select(restoring: false)
        await rig.controller.turnOn(for: try rig.currentBinding())
        try await rig.drop()
        await rig.store.upsert(rig.endpoint)
        try await rig.expectStopped(.endpointChanged)
        await rig.close()
    }

    @Test(arguments: [true, false])
    func differentHostOrTargetStillVetoes(hostChanged: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let other = AmbientAudioBinding(hostID: hostChanged ? "other-synthetic-host" : rig.endpoint.id,
                                       targetID: hostChanged ? rig.target.id : "tmux:other",
                                       connectionGeneration: UUID(), selection: 0)
        await rig.controller.update(binding: other, scene: .background)
        try await rig.expectStopped(.bindingChanged)
        await rig.close()
    }

    @Test(arguments: [false, true])
    func missingOrDeadRetainedTargetAfterRefreshFailsClosed(dead: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        var refreshed = rig.endpoint
        refreshed.name = "Refreshed synthetic host"
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: refreshed.url)
        await rig.store.upsert(refreshed)
        try await waitUntil { try await rig.socket.sentFrames().contains { if case .control(.hello) = $0.payload {
            return true
        }; return false } }
        try await rig.socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
            capabilities: ["ping", "select_target", "stream_audio"], deviceName: "Synthetic")))
        var target = rig.target
        target.alive = false
        try await rig.socket.push(.targets(dead ? [target] : []))
        try await rig.expectStopped(.targetChanged)
        #expect(try await audioFrames(rig.socket).isEmpty)
        await rig.close()
    }

    private func replace(_ rig: AmbientReconnectRig, endpoint: HostEndpoint) async throws {
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: endpoint.url)
        await rig.store.upsert(endpoint)
        try await rig.handshake(rig.socket)
    }

    private func confirmRefreshPrivacy(_ rig: AmbientReconnectRig) async throws {
        try await waitUntil { try await rig.socket.sentFrames().contains {
            $0.payload == .control(.setPrivacy(on: true))
        } }
        #expect(try await audioFrames(rig.socket).isEmpty)
        try await rig.socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run { rig.controller.binding?.connectionGeneration
            == rig.store.snapshots[rig.endpoint.id]?.connectionGeneration } }
    }
}
