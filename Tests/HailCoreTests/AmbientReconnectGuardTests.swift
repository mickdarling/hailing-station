import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectGuardTests {
    @Test func ownerStopWhileRestartAwaitsPermissionWins() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let gate = SleepGate()
        rig.permissionGate = gate
        let reconnecting = Task { try await rig.reconnect() }
        try await waitUntil { await gate.isWaiting() }
        await rig.controller.turnOff()
        await gate.fire()
        try await reconnecting.value
        try await rig.expectStopped(.ownerStop)
        #expect(rig.makeCalls == 1)
        await rig.close()
    }

    @Test func privacyEnteringWhileRestartAwaitsPermissionWins() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let gate = SleepGate()
        rig.permissionGate = gate
        let reconnecting = Task { try await rig.reconnect() }
        try await waitUntil { await gate.isWaiting() }
        try await rig.socket.push(.duckMode(on: true))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        await gate.fire()
        try await reconnecting.value
        try await rig.expectStopped(.privacy)
        #expect(rig.makeCalls == 1)
        await rig.close()
    }

    @Test func backgroundReconnectStopsWithoutWaitingToStartOnForeground() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        await rig.controller.update(binding: try rig.currentBinding(), scene: .background)
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await rig.expectStopped(.background)
        await rig.controller.update(binding: nil, scene: .active)
        try await rig.select(restoring: true)
        #expect(rig.capture.startCount == 1)
        await rig.close()
    }

    @Test func aRelaunchDoesNotInheritPendingIntent() async throws {
        let old = try AmbientReconnectRig()
        try await old.start()
        try await old.drop()
        let fresh = try AmbientReconnectRig()
        try await fresh.start(listening: false)
        #expect(!fresh.controller.isOn)
        #expect(fresh.capture.startCount == 0)
        #expect(fresh.notices.isEmpty)
        await fresh.close()
        await old.close()
    }

    @Test func protocolFailureIsNotATransportDrop() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.error(code: .malformed, message: "synthetic protocol failure"))
        try await waitUntil { await MainActor.run {
            if case .failed = rig.store.snapshots[rig.endpoint.id]?.state { return true }; return false
        } }
        await rig.controller.update(binding: nil, scene: .active)
        #expect(!rig.controller.reconnect.isPending)
        #expect(rig.notices.isEmpty)
        #expect(rig.capture.startCount == 1)
        await rig.close()
    }

    @Test func preexistingPrivacyBlocksEvenIfNewHostIsPublic() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.duckMode(on: true))
        try await waitUntil { await MainActor.run { rig.store.duckMode[rig.endpoint.id]?.on == true } }
        try await rig.drop()
        try await rig.reconnect()
        try await rig.expectStopped(.privacy)
        await rig.close()
    }

    @Test func changedTargetIdentityCannotRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        var changed = rig.target
        changed.name = "Changed synthetic target"
        try await rig.socket.push(.targets([changed]))
        try await rig.expectStopped(.targetChanged)
        await rig.close()
    }

    @Test(arguments: [AmbientListeningReconnect.Outcome.applied, .blocked, .failed])
    func diagnosticsContainOnlyEnumeratedOutcomeAndReason(outcome: AmbientListeningReconnect.Outcome) async throws {
        let suite = "hail-904-reconnect-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        let rig = try AmbientReconnectRig()
        rig.controller.diagnostics = log
        try await rig.start()
        try await rig.drop()
        if outcome == .blocked { await rig.controller.turnOff() }
        rig.failStart = outcome == .failed
        try await rig.reconnect()
        let events = log.nextBatch()?.events.filter { $0.name == .captureState } ?? []
        #expect(events.count == 1)
        let reason: Int64 = outcome == .applied ? 0 : (outcome == .blocked ? 1 : 10)
        #expect(events.first?.fields == [
            .state: .token("reconnecting"), .on: .boolean(outcome == .applied),
            .code: .token(outcome == .failed ? "resume_failed" : "other"), .error: .integer(reason)
        ])
        await rig.close()
    }
}
