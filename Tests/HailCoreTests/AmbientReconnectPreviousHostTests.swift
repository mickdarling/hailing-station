import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectPreviousHostTests {
    @Test(arguments: [false, true])
    func removingPriorRestoredHostMustNotVetoCurrentHostsRecovery(removePrevious: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        #expect(rig.controller.reconnect.binding?.hostID == rig.endpoint.id)
        await rig.controller.turnOff()
        let second = try endpoint("second", "ws://127.0.0.1:8770")
        let secondSocket = try await connectSecondHost(second, rig: rig)
        try await selectSecondHost(second, socket: secondSocket, rig: rig)
        let binding = try #require(rig.store.ambientBinding(host: second.id, targetID: rig.target.id))
        await rig.controller.turnOn(for: binding)
        #expect(rig.controller.isListening && rig.controller.binding?.hostID == second.id)
        if removePrevious { await rig.store.remove(rig.endpoint.id) } // Bound host B stays untouched.
        #expect(rig.controller.isListening)
        await secondSocket.fail()
        try await waitUntil { await rig.retry.isWaiting() }
        #expect(rig.controller.reconnect.isPending,
            "A stale previous-host recovery binding latched an unrelated endpoint-removal veto")
        #expect(rig.controller.isListening,
            "Current host's transport drop must retain capture after only the old host was removed")
        await rig.close()
        await rig.store.disconnect(second.id)
    }

    private func connectSecondHost(_ second: HostEndpoint, rig: AmbientReconnectRig) async throws -> ScriptedSocket {
        let socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(socket), for: second.url)
        await rig.store.upsert(second)
        await rig.store.connect(second.id)
        try await waitUntil { try await socket.sentFrames().contains {
            if case .control(.hello) = $0.payload { return true }; return false
        } }
        try await socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
            capabilities: ["ping", "select_target", "stream_audio", "set_privacy"], deviceName: "Synthetic")))
        try await socket.push(.targets([rig.target]))
        try await waitUntil { await MainActor.run {
            rig.store.snapshots[second.id]?.receivedTargetList == true
        } }
        return socket
    }

    private func selectSecondHost(_ second: HostEndpoint, socket: ScriptedSocket,
                                  rig: AmbientReconnectRig) async throws {
        let selection = Task { try await rig.store.selectTarget(host: second.id, targetID: rig.target.id) }
        try await waitUntil { try await socket.sentFrames().contains {
            if case .control(.select) = $0.payload { return true }; return false
        } }
        try await waitUntil { try await socket.sentFrames().filter {
            if case .control(.ping) = $0.payload { return true }; return false
        }.count >= 2 }
        let pings = try await socket.sentFrames().compactMap { frame -> String? in
            if case .control(.ping(let nonce)) = frame.payload { return nonce }; return nil
        }
        try await socket.push(.pong(nonce: try #require(pings.last)))
        try await selection.value
    }
}
