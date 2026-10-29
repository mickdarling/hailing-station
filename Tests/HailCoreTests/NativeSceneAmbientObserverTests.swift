#if os(macOS)
import Foundation
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct NativeSceneAmbientObserverTests {
    @Test func nativeRootObserverStopsDeselectedDestinationWhileToolCoversCard() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        let suite = "hail-native-root-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        let resources = StationResources(connections: rig.store, backend: FakeAudioSessionBackend(inputs: []),
            player: FormatTestPlayer(), keepaliveRenderer: FakeKeepaliveRenderer(), diagnostics: log)
        let probe = NativeSceneAmbientProbe(binding: try rig.currentBinding())
        let host = NativeSceneAmbientHost(resources: resources, probe: probe)
        defer { host.finish() }
        await host.render()
        let root = try #require(probe.root)
        #expect(root.ambientDestinationBinding == (try rig.currentBinding()))
        await rig.controller.turnOn(for: try rig.currentBinding())
        await host.render()
        probe.toolShown = true
        await host.render()
        #expect(probe.disappearances == 1 && rig.controller.isListening && rig.released == 0)
        #expect(!(log.nextBatch()?.events ?? []).contains { $0.name == .ambientStop })
        root.selectedTargetID = nil // Core still confirms its target; only the shipped root observer sees this loss.
        await host.render()
        #expect(root.ambientDestinationBinding == nil)
        #expect(!rig.controller.isOn && !rig.controller.isListening)
        let stops = (log.nextBatch()?.events ?? []).filter { $0.name == .ambientStop }
        #expect(stops.count == 1 && stops.first?.fields[.reason] == .token("binding_changed"))
        probe.toolShown = false
        await host.render()
        #expect(rig.controller.stopReason != nil)
        if let reason = rig.controller.stopReason {
            let visible = host.visibleText().joined(separator: " ")
            #expect(visible.contains(reason), "The genuine loss reason must remain visible without a card")
        }
        await rig.close()
    }
}
#endif
