import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectSuspensionTests {
    @Test func offRevokesResumeInsideTransportSelectionConfirmation() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect(selectTarget: false)
        try await waitUntil { try await rig.selectionPing(after: 0) != nil }
        let nonce = try #require(try await rig.selectionPing(after: 0))
        for index in 0..<6 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        let off = Task { await rig.controller.turnOff() }
        try await waitUntil { await MainActor.run { !rig.controller.isOn } }
        try await rig.socket.push(.pong(nonce: nonce))
        await off.value
        try await waitUntil { await MainActor.run {
            rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) != nil
        } }
        #expect(try await audioFrames(rig.socket).isEmpty)
        #expect(rig.capture.startCount == 1 && rig.released == 1)
        #expect(rig.notices.map(\.outcome) == [.blocked] && rig.notices.last?.reason == .ownerStop)
        await rig.close()
    }

    @Test func newerDestinationOwnsSelectionWhileTheOlderOneDrains() async throws {
        let held = SleepGate()
        let rig = try AmbientSuspensionFixtures.heldSender(held)
        try await rig.start()
        try await rig.socket.push(.targets([rig.target,
            TargetInfo(id: "tmux:b", kind: "tmux", name: "B", alive: true),
            TargetInfo(id: "tmux:c", kind: "tmux", name: "C", alive: true)]))
        for index in 0..<6 { try rig.capture.yield(sineBuffer(offset: index * 4_800)) }
        try await waitUntil { await held.isWaiting() }
        // The binding observer ends the old controller while its sender is still draining.
        let draining = Task { await rig.controller.update(binding: nil, scene: .active) }
        try await waitUntil { await MainActor.run { !rig.controller.isOn } }
        let (older, olderPing) = try await AmbientSuspensionFixtures.select("tmux:b", rig: rig)
        let (newer, newerPing) = try await AmbientSuspensionFixtures.select("tmux:c", rig: rig)
        try await rig.socket.push(.pong(nonce: newerPing))
        try await newer.value
        try await rig.socket.push(.pong(nonce: olderPing))
        try await older.value
        let final = try #require(rig.store.ambientBinding(host: rig.endpoint.id, targetID: "tmux:c"))
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: "tmux:b") == nil)
        await held.fire()
        await draining.value
        #expect(try await audioFrames(rig.socket).isEmpty)
        try await rig.store.sendAudio(ambientSegment(), to: final)
        #expect(try await audioFrames(rig.socket).map(\.target) == ["tmux:c"])
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: "tmux:c") == final)
        await rig.close()
    }
}

@MainActor
enum AmbientSuspensionFixtures {
    static func heldSender(_ held: SleepGate) throws -> AmbientReconnectRig {
        let rig = try AmbientReconnectRig()
        let store = rig.store
        rig.controller = AmbientListeningController(
            notificationCenter: rig.center, requestPermission: { true },
            makeStreamer: { AmbientAudioStreamer(capture: rig.capture, send: $0) },
            releaseSession: { rig.released += 1 }, send: { audio, binding in
                try await held.sleep(.zero)
                try await store.sendAudio(audio, to: binding)
            }
        )
        return rig
    }

    static func select(_ target: String, rig: AmbientReconnectRig) async throws -> (Task<Void, any Error>, String) {
        let count = try await rig.socket.sentFrames().count
        let selecting = Task { try await rig.store.selectTarget(host: rig.endpoint.id, targetID: target) }
        try await waitUntil { try await rig.selectionPing(after: count) != nil }
        return (selecting, try #require(try await rig.selectionPing(after: count)))
    }
}
