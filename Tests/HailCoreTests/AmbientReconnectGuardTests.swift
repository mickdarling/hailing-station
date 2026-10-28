import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectGuardTests {
    @Test(arguments: [true, false]) func eitherPrivacySwitchDirectionStopsDuringGapImmediately(on: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try? await rig.store.setPrivacy(on: on, host: rig.endpoint.id)
        try await rig.expectStopped(.privacy)
        try await rig.reconnect()
        #expect(rig.notices.count == 1)
        await rig.close()
    }
    @Test(arguments: [AmbientListeningReconnect.Reason.ownerStop, .ownerSelection, .explicitDisconnect,
                       .endpointChanged, .bindingChanged])
    func eachOwnerGuardStopsDuringGapImmediately(reason: AmbientListeningReconnect.Reason) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        switch reason {
        case .ownerStop: await rig.controller.turnOff()
        case .ownerSelection: try? await rig.store.selectTarget(host: rig.endpoint.id, targetID: "tmux:other")
        case .explicitDisconnect: await rig.store.disconnect(rig.endpoint.id)
        case .endpointChanged: await rig.store.remove(rig.endpoint.id)
        default:
            let other = AmbientAudioBinding(hostID: rig.endpoint.id, targetID: "other",
                                             connectionGeneration: UUID(), selection: 2)
            await rig.controller.update(binding: other, scene: .background)
        }
        try await rig.expectStopped(reason)
        await rig.close()
    }
    @Test func knownMediaBeforeDropRestoresWithoutAGate() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.mediaMode(on: true))
        try await waitUntil { await MainActor.run { rig.store.mediaMode[rig.endpoint.id]?.on == true } }
        try await rig.drop()
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }
    @Test(arguments: [ControlPayload.duckMode(on: true, reason: "device"), .mediaMode(on: true)])
    func hostModeBeforeReauthorizationNeverVetoes(mode: ControlPayload) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false, mode: mode)
        try await rig.select(restoring: true)
        if case .duckMode = mode {
            try await waitUntil { try await rig.socket.sentFrames().contains {
                $0.payload == .control(.setPrivacy(on: true))
            } }
            try await rig.socket.push(.duckMode(on: true, reason: "device"))
            try await waitUntil { await MainActor.run { rig.controller.binding?.connectionGeneration
                == rig.store.snapshots[rig.endpoint.id]?.connectionGeneration } }
        }
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }
    @Test(arguments: [true, false]) func removedOrChangedTargetStopsImmediately(remove: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        var changed = rig.target
        changed.name = "Changed synthetic target"
        try await rig.socket.push(.targets(remove ? [] : [changed]))
        try await rig.expectStopped(.targetChanged)
        await rig.close()
    }
    @Test func explicitDisconnectAndProtocolFailureNeverArmRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.error(code: .malformed, message: "synthetic protocol failure"))
        try await waitUntil { await MainActor.run {
            if case .failed = rig.store.snapshots[rig.endpoint.id]?.state { return true }; return false
        } }
        await rig.controller.update(binding: nil, scene: .active)
        #expect(!rig.controller.reconnect.isPending && rig.notices.isEmpty)
        await rig.close()
    }
}
