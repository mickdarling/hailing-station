import Foundation
import HailProtocol
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
        let selection = try await pendingSelection()
        failedSocket = rig.socket
        clock.advance(by: .seconds(55))
        await rig.socket.fail()
        let closing = try #require(closing)
        try await waitUntil { await closing.gate.isWaiting() }
        // Observe completion directly, whether teardown releases the waiter with success or notReady.
        _ = await selection.result
        return original
    }

    func refusePrivateSelection() async throws {
        let clock = clock
        rig.controller.reconnect.now = { clock.now() }
        rig.controller.reconnect.sleep = { _ in throw CancellationError() }
        try await rig.start()
        try await rig.confirmInitialPrivacy()
        try await rig.drop()
        rig.wrapReconnect = { [weak self] base in
            let wrapped = AmbientClosingSocket(base: base)
            self?.closing = wrapped
            return wrapped
        }
        try await rig.reconnect(selectTarget: false)
        try await waitUntil { try await self.rig.selectionPing(after: 0) != nil }
        let selection = try await pendingSelection()
        failedSocket = rig.socket
        try await rig.socket.push(.error(code: .unauthorized, message: "selection requires owner authorization"))
        let closing = try #require(closing)
        try await waitUntil { await closing.gate.isWaiting() }
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
        // Hold failure publication until the latest restoring select has completed. No pong is supplied.
        if case .success = await selection.result {
            try await waitUntil { await MainActor.run { !self.rig.controller.isOn } }
        }
        await closing.gate.fire()
        try await waitUntil { await MainActor.run {
            if case .failed = self.rig.store.snapshots[self.rig.endpoint.id]?.state { return true }; return false
        } }
    }

    private func pendingSelection() async throws -> Task<Void, any Error> {
        let count = try await rig.socket.sentFrames().count
        let rig = rig
        // Supersede the automatic select so this task owns the store's completion and can be awaited directly.
        let selection = Task {
            try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id, restoring: true)
        }
        try await waitUntil { try await rig.selectionPing(after: count) != nil }
        return selection
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
