import Foundation
import Testing
@testable import HailCore

/// Hold teardown after the loss observer closes admission but before reconnecting reaches the store.
@MainActor
final class AmbientClosingSelectionRun {
    let rig: AmbientReconnectRig
    let clock = TestInstantClock()
    private var closing: AmbientClosingSocket?
    private var failedSocket: ScriptedSocket?

    init() throws { rig = try AmbientReconnectRig() }

    func holdCloseDuringSelection() async throws -> AmbientAudioBinding {
        let clock = clock
        rig.controller.reconnect.now = { clock.now() }
        rig.controller.reconnect.sleep = { _ in throw CancellationError() }
        try await rig.start()
        let original = try rig.currentBinding()
        try await rig.drop()
        rig.wrapReconnect = { [weak self] base in
            let wrapped = AmbientClosingSocket(base: base)
            self?.closing = wrapped
            return wrapped
        }
        try await rig.reconnect(selectTarget: false)
        try await waitUntil { try await self.rig.selectionPing(after: 0) != nil }
        failedSocket = rig.socket
        clock.advance(by: .seconds(55))
        await rig.socket.fail()
        let closing = try #require(closing)
        try await waitUntil { await closing.gate.isWaiting() }
        // Cleanup removed the pending ping while the snapshot still says ready; let its waiter finish.
        try await waitUntil { await MainActor.run {
            self.rig.store.ambientBinding(host: self.rig.endpoint.id, targetID: self.rig.target.id) != nil
        } }
        return original
    }

    func releaseClose() async throws {
        await closing?.gate.fire()
        try await waitUntil { await self.rig.retry.isWaiting() }
        rig.wrapReconnect = { $0 }
    }

    func expectNoGapAudioOrPrivacyOff() async throws {
        let failedSocket = try #require(failedSocket)
        #expect(try await failedSocket.sentFrames().allSatisfy { frame in
            if case .audio = frame.payload { return false }; return true
        })
        for socket in [failedSocket, rig.socket] {
            #expect(try await socket.sentFrames().allSatisfy { frame in
                if case .control(.setPrivacy(on: false)) = frame.payload { return false }; return true
            })
        }
    }
}
