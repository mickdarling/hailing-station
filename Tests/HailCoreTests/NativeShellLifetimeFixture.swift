#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Real native root/shell/card, with the existing synthetic ambient transport and capture rig.
@MainActor
struct NativeShellLifetimeFixture {
    let rig: AmbientReconnectRig
    let probe: NativeSceneAmbientProbe
    let host: NativeSceneAmbientHost
    let root: StationRootView
    let binding: AmbientAudioBinding

    static func start() async throws -> Self {
        NativeShellLaunchContext.install()
        try #require(StationRedesignLaunch.flags.isOn(.shell), "Run in the dedicated flag-on test process")
        let rig = try AmbientReconnectRig()
        var mounted: NativeSceneAmbientHost?
        do {
            try await rig.start(listening: false)
            let binding = try rig.currentBinding()
            let probe = NativeSceneAmbientProbe(binding: binding)
            #expect(probe.stationVisibility == .unobserved)
            let defaults = try #require(UserDefaults(suiteName: "hail-shell-proof-\(UUID().uuidString)"))
            let resources = StationResources(connections: rig.store, backend: FakeAudioSessionBackend(inputs: []),
                player: FormatTestPlayer(), keepaliveRenderer: FakeKeepaliveRenderer(),
                diagnostics: DeviceDiagnostics(defaults: defaults, appInfo: [:]))
            try #require(!resources.diagnostics.isEnabled, "The synthetic fixture must not collect diagnostic events")
            let host = NativeSceneAmbientHost(resources: resources, probe: probe, width: 1_100)
            mounted = host
            await host.render()
            try await waitUntil { await MainActor.run {
                probe.root?.ambientDestinationBinding == binding && probe.appearances > 0
                    && probe.stationVisibility == .visible && rig.controller.onListeningChange != nil
            } }
            await host.render()
            let root = try #require(probe.root)
            await rig.controller.turnOn(for: binding) // The already-mounted real card uses this existing fake owner.
            return Self(rig: rig, probe: probe, host: host, root: root, binding: binding)
        } catch {
            mounted?.finish()
            await rig.close()
            throw error
        }
    }

    func assertContinuedDelivery() async throws {
        #expect(root.connections === rig.store && rig.store.ambientController === rig.controller)
        #expect(rig.controller.binding == binding && root.ambientDestinationBinding == binding)
        try #require(rig.controller.isOn && rig.controller.isListening)
        #expect(rig.store.ambientStreaming, "The actual card installed the controller's activity callback")
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount == 0 && rig.released == 0)
        #expect(rig.permissionCalls == 1 && rig.makeCalls == 1)
        let before = try await audioFrames(rig.socket).count
        try await rig.feed()
        try await waitUntil { try await audioFrames(rig.socket).count > before }
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        #expect(rig.capture.stopCount == 0 && rig.released == 0)
    }

    func select(_ section: StationSection) async throws {
        root.navigation.apply(.select(section))
        await host.render()
        let expected: NativeSceneAmbientProbe.StationVisibility = section == .station ? .visible : .hidden
        try await waitUntil { await MainActor.run { probe.stationVisibility == expected } }
        #expect(root.navigation.section == section)
        try await assertContinuedDelivery()
    }

    func close() async {
        host.finish()
        await rig.close()
    }
}
#endif
