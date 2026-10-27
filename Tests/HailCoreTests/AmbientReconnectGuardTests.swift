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
    @Test(arguments: [ControlPayload.duckMode(on: true), .mediaMode(on: true)])
    func knownModesBeforeDropBlockEvenIfFreshConnectionIsPublic(mode: ControlPayload) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(mode)
        let privacy = mode == .duckMode(on: true)
        try await waitUntil { await MainActor.run {
            privacy ? rig.store.duckMode[rig.endpoint.id]?.on == true : rig.store.mediaMode[rig.endpoint.id]?.on == true
        } }
        try await rig.drop()
        try await rig.expectStopped(privacy ? .privacy : .modeChanged)
        try await rig.reconnect()
        #expect(rig.notices.count == 1)
        await rig.close()
    }
    @Test(arguments: [ControlPayload.duckMode(on: true), .mediaMode(on: true)])
    func stoppingHostModeBeforeReauthorizationStopsImmediately(mode: ControlPayload) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false, mode: mode)
        try await rig.expectStopped(mode == .duckMode(on: true) ? .privacy : .modeChanged)
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
