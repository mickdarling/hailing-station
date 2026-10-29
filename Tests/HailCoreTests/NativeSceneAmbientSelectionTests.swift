#if os(macOS)
import Foundation
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct NativeSceneAmbientSelectionTests {
    enum OwnerChange: CaseIterable, Sendable { case deselectTarget, deselectHost, changeTarget, changeHost }

    @Test(arguments: OwnerChange.allCases)
    func ownerSelectionDuringPendingRestoreVetoesResumeWhileToolCoversCard(_ change: OwnerChange) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        let probe = NativeSceneAmbientProbe(binding: try rig.currentBinding())
        let host = makeHost(rig, probe)
        defer { host.finish() }
        await host.render()
        let root = try #require(probe.root)
        await rig.controller.turnOn(for: try rig.currentBinding())
        probe.toolShown = true
        await host.render()
        try await rig.drop()
        await host.render()
        #expect(root.ambientDestinationBinding == nil && rig.controller.reconnect.isPending)
        switch change {
        case .deselectTarget: root.selectedTargetID = nil
        case .deselectHost: root.selectedHostID = nil
        case .changeTarget: root.selectedTargetID = "tmux:other"
        case .changeHost: root.selectedHostID = "synthetic-other-host"
        }
        await host.render()
        #expect(root.ambientDestinationBinding == nil)
        #expect(!rig.controller.isOn && !rig.controller.isListening && !rig.controller.reconnect.isPending)
        try await rig.reconnect()
        await host.render()
        #expect(!rig.controller.isOn && !rig.controller.isListening && rig.released == 1)
        #expect(rig.capture.startCount == 1)
        probe.toolShown = false
        await host.render()
        #expect(!rig.controller.isOn)
        await rig.close()
    }

    @Test(arguments: [false, true])
    func unchangedOwnerSelectionSurvivesToolAndGenerationChange(toolCovered: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        let original = try rig.currentBinding()
        let probe = NativeSceneAmbientProbe(binding: original)
        let host = makeHost(rig, probe)
        defer { host.finish() }
        await host.render()
        await rig.controller.turnOn(for: original)
        probe.toolShown = toolCovered
        await host.render()
        try await rig.drop()
        await host.render()
        #expect(rig.controller.reconnect.isPending && rig.controller.isListening)
        try await rig.reconnect(selectTarget: false)
        await host.render()
        #expect(rig.controller.isListening && rig.released == 0)
        try await rig.select(restoring: true)
        await host.render()
        try await rig.feed()
        await host.render()
        let restored = try rig.currentBinding()
        #expect(restored.connectionGeneration != original.connectionGeneration)
        #expect(rig.controller.binding == restored && probe.root?.ambientDestinationBinding == restored)
        #expect(rig.controller.isListening && rig.released == 0)
        probe.toolShown = false
        await host.render()
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        await rig.close()
    }

    private func makeHost(_ rig: AmbientReconnectRig, _ probe: NativeSceneAmbientProbe) -> NativeSceneAmbientHost {
        NativeSceneAmbientHost(resources: StationResources(connections: rig.store,
            backend: FakeAudioSessionBackend(inputs: []), player: FormatTestPlayer(),
            keepaliveRenderer: FakeKeepaliveRenderer()), probe: probe)
    }
}
#endif
