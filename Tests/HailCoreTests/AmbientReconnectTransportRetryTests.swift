import Foundation
import Testing
@testable import HailCore

/// Synthetic transport proof: ending ambient recovery never ends ordinary connection intent.
@MainActor
@Suite(.serialized) struct AmbientReconnectTransportRetryTests {
    @Test(arguments: [false, true])
    func ownerVetoMidWaitStillReconnectsWithoutResumingAmbient(privacy: Bool) async throws {
        let steps = AmbientRetrySteps()
        let rig = try AmbientReconnectRig(retrySleep: { try await steps.sleep($0) })
        try await rig.start()
        await rig.socket.fail()
        try await waitUntil { await steps.started == 1 }
        if privacy { try? await rig.store.setPrivacy(on: true, host: rig.endpoint.id) } else {
            await rig.controller.turnOff()
        }
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        try await waitUntil { await steps.started == 2 }
        #expect(await steps.durations.last == .seconds(1))
        let notices = rig.notices
        let binding = rig.controller.binding
        let stops = rig.capture.stopCount
        // The cancelled ambient sleeper is still held. Only the ordinary wait can authorize this connection.
        try await reconnectTransport(rig, steps: steps, index: 1)
        try await expectNoAmbientRestore(rig)
        await steps.release(0)
        await settle()
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == 2)
        // A later independent drop must also retain ordinary transport retries without an ambient owner start.
        await rig.socket.fail()
        try await waitUntil { await steps.started == 3 }
        #expect(await steps.durations.last == .seconds(1))
        try await reconnectTransport(rig, steps: steps, index: 2)
        try await expectNoAmbientRestore(rig)
        #expect(rig.notices == notices && rig.controller.binding == binding)
        #expect(rig.notices.last?.reason == (privacy ? .privacy : .ownerStop))
        #expect(rig.capture.startCount == 1 && rig.capture.stopCount == stops && stops >= 1)
        #expect(rig.released == 1 && rig.unexpected.isEmpty)
        await rig.close()
        await steps.releaseAll()
    }

    @Test func flappingPathKeepsOrdinaryRetriesBehindTheFirstScheduledDelay() async throws {
        let steps = AmbientRetrySteps()
        let endpoint = try endpoint()
        let connector = ScriptedConnector()
        let connection = HostConnection(
            endpoint: endpoint, connector: connector, schedule: ReconnectSchedule(baseDelays: [3, 6]),
            deadlineSleep: { _ in throw CancellationError() },
            sleep: { try await steps.sleep($0) }, jitter: { 0.5 }
        )
        await connection.connect()
        try await waitUntil { await steps.started == 1 }
        for index in 0..<8 {
            await connection.networkPathChanged()
            try await waitUntil { await steps.started == index + 2 }
            #expect(await steps.durations.last == .seconds(3))
            await steps.release(index)
            await settle()
            #expect(await connector.openCount(for: endpoint.url) == 1)
        }
        await steps.release(8)
        try await waitUntil { await steps.started == 10 }
        #expect(await connector.openCount(for: endpoint.url) == 2)
        #expect(await steps.durations.last == .seconds(6))
        await connection.disconnect()
        await steps.releaseAll()
    }
}

private extension AmbientReconnectTransportRetryTests {
    func reconnectTransport(_ rig: AmbientReconnectRig, steps: AmbientRetrySteps, index: Int) async throws {
        rig.socket = ScriptedSocket()
        await rig.connector.enqueue(.socket(rig.socket), for: rig.endpoint.url)
        await steps.release(index)
        try await rig.handshake(rig.socket)
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
    }

    func expectNoAmbientRestore(_ rig: AmbientReconnectRig) async throws {
        #expect(!rig.controller.isOn && !rig.controller.isListening)
        #expect(!rig.controller.reconnect.isPending && rig.controller.reconnect.status == nil)
        #expect(rig.controller.reconnect.pacing == nil)
        let frames = try await rig.socket.sentFrames()
        let noAmbientRestore: Bool = frames.allSatisfy { frame in
            switch frame.payload {
            // .audio includes sequence-zero streamID binding/start frames and isResume starts.
            // .control(.select) only restores the ordinary tap-to-talk/reply destination.
            case .audio, .control(.ambientInput), .control(.setPrivacy): return false
            default: return true
            }
        }
        #expect(noAmbientRestore)
    }
}
