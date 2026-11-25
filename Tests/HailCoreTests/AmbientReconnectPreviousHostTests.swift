import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectPreviousHostTests {
    @Test(arguments: [false, true])
    func confirmedHostSwitchKeepsTheRootsStopAttribution(discardConfirmation: Bool) async throws {
        let run = try OwnerDestinationRun()
        let rig = run.rig
        try await run.start()
        let root = try RootView(rig: rig, selectionStore: RootSelectionStore())
        let original = try rig.currentBinding()
        let second = try endpoint("second", "ws://127.0.0.1:8770")
        let socket = try await connectSecondHost(second, rig: rig)
        let selection = Task { await root.select(Destination(endpoint: second, target: rig.target)) }
        try await confirmSecondSelection(socket) {
            if discardConfirmation {
                root.scenePhase = .background
                root.scenePhaseRevision &+= 1
            }
        }
        await selection.value
        #expect(rig.store.ambientBinding(host: second.id, targetID: rig.target.id)?.targetID == rig.target.id)
        #expect(try rig.currentBinding() == original)
        #expect(rig.controller.isListening && rig.controller.binding == original)
        if discardConfirmation {
            #expect(root.ambientDestinationBinding == original)
            await root.reconcileAmbientDestination()
            #expect(rig.controller.isListening && rig.controller.binding == original)
            try await rig.removeAdvertisedTargets()
            #expect(root.ambientDestinationBinding == nil)
            await root.reconcileAmbientDestination()
            #expect(rig.controller.listeningState == .stopped(.targetRemoved))
        } else {
            #expect(root.ambientDestinationBinding?.hostID == second.id)
            await root.reconcileAmbientDestination()
            #expect(rig.controller.listeningState == .stopped(.ownerReselect))
        }
        #expect(rig.controller.stopReason == OwnerDestinationRun.reason && rig.released == 1)
        #expect(run.stops().map { $0.fields[.reason] } == [.token("binding_changed")])
        await rig.close()
        await rig.store.disconnect(second.id)
    }

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

    #if os(macOS)
    @Test(.enabled(if: NativeShellLaunchContext.optedIn))
    func flagOnPrivacyStaysDisabledUntilTheDisplayedHostsBindingMatches() async throws {
        NativeShellLaunchContext.install()
        try #require(StationRedesignLaunch.flags.isOn(.shell))
        let rig = try AmbientReconnectRig()
        let second = try endpoint("second", "ws://station-b.invalid")
        do {
            try await rig.start()
            let socket = try await connectSecondHost(second, rig: rig)
            try await selectSecondHost(second, socket: socket, rig: rig)
            let binding = try #require(rig.store.ambientBinding(host: second.id, targetID: rig.target.id))
            try await socket.push(.duckMode(on: true, reason: "device"))
            try await waitUntil { await MainActor.run { rig.store.privacySwitch(second.id).isPrivate } }
            rig.store.notePrivateStop(HostConnectionFailure.remote("not_allowed: ambient stopped: fixture"),
                                      binding: binding)
            let owner = PrivacySettingsFixture(connections: rig.store, host: second.id)
            func displayed() -> StationScreenPrivacy {
                StationScreenPrivacy(displayedHost: second.id, binding: binding,
                    liveBinding: rig.controller.binding, settings: owner.privacySettingsState())
            }
            let settings = owner.privacySettingsState()
            try #require(settings.privacy.shown == .privateListeningUnavailable && settings.canRequestPrivacy)
            try #require(rig.controller.isListening && rig.controller.binding?.hostID == rig.endpoint.id)
            let mismatch = displayed()
            #expect(mismatch.privacy == nil && mismatch.intent == nil && !mismatch.dockEnabled)

            await rig.controller.turnOff()
            await rig.controller.turnOn(for: binding)
            try #require(rig.controller.isListening && rig.controller.binding == binding)
            let matched = displayed()
            #expect(matched.title == "Leave private mode" && matched.dockEnabled)
            #expect(matched.intent == .privacy(false, host: second.id, generation: binding.connectionGeneration))
            let frames = try await socket.sentFrames()
            #expect(!frames.contains { if case .control(.setPrivacy) = $0.payload { true } else { false } })
        } catch {
            await rig.close()
            await rig.store.disconnect(second.id)
            throw error
        }
        await rig.close()
        await rig.store.disconnect(second.id)
    }
    #endif

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
        try await confirmSecondSelection(socket)
        try await selection.value
    }

    private func confirmSecondSelection(_ socket: ScriptedSocket, beforePong: () -> Void = {}) async throws {
        try await waitUntil { try await socket.sentFrames().contains {
            if case .control(.select) = $0.payload { return true }; return false
        } }
        try await waitUntil { try await socket.sentFrames().filter {
            if case .control(.ping) = $0.payload { return true }; return false
        }.count >= 2 }
        let pings = try await socket.sentFrames().compactMap { frame -> String? in
            if case .control(.ping(let nonce)) = frame.payload { return nonce }; return nil
        }
        beforePong()
        try await socket.push(.pong(nonce: try #require(pings.last)))
    }
}
