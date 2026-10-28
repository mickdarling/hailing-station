import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAdditionalGuardTests {
    @Test func pendingPrivacyRequestBeforeDropRemainsAVeto() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.store.setPrivacy(on: true, host: rig.endpoint.id)
        #expect(rig.store.privacyLocal[rig.endpoint.id]?.request != nil)
        try await rig.drop()
        try await rig.expectStopped(.privacy)
        await rig.close()
    }
    @Test func stoppingInterruptionDuringGapEndsInsteadOfStartingAnInterruptionResumer() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        rig.capture.stop()
        rig.center.post(name: AVAudioEngineCapture.endedBySystem, object: nil,
                        userInfo: [AVAudioEngineCapture.endedCauseKey: AVAudioEngineCapture.interruptionCause])
        try await rig.expectStopped(.modeChanged)
        #expect(rig.controller.pausedReason == nil && rig.unexpected.isEmpty)
        await rig.close()
    }
    @Test func captureEndingDuringGapReportsFailureOnce() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        rig.capture.stop()
        try await waitUntil { await MainActor.run { !rig.controller.isOn } }
        #expect(rig.notices.count == 1 && rig.notices[0].outcome == .failed)
        #expect(rig.unexpected.isEmpty)
        await rig.close()
    }
    @Test func overlappingReauthorizationsOnlyPublishTheNewestConfirmation() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start(listening: false)
        let other = TargetInfo(id: "tmux:other", kind: "tmux", name: "Other", alive: true)
        try await rig.socket.push(.targets([rig.target, other]))
        try await waitUntil { await MainActor.run {
            rig.store.snapshots[rig.endpoint.id]?.targets.contains(other) == true
        } }
        let count = try await rig.socket.sentFrames().count
        let first = Task { try await rig.store.selectTarget(host: rig.endpoint.id,
                                                           targetID: rig.target.id, restoring: true) }
        try await waitUntil { try await rig.selectionPing(after: count) != nil }
        let firstPing = try #require(try await rig.selectionPing(after: count))
        let secondCount = try await rig.socket.sentFrames().count
        let second = Task { try await rig.store.selectTarget(host: rig.endpoint.id,
                                                            targetID: "tmux:other", restoring: true) }
        try await waitUntil { try await rig.selectionPing(after: secondCount) != nil }
        let secondPing = try #require(try await rig.selectionPing(after: secondCount))
        try await rig.socket.push(.pong(nonce: firstPing))
        try await first.value
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) == nil)
        try await rig.socket.push(.pong(nonce: secondPing))
        try await second.value
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: "tmux:other") != nil)
        await rig.close()
    }
    @Test func oldStreamFailureCannotArmRecoveryForReplacementCapture() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        let binding = try rig.currentBinding()
        try await rig.feed()
        try await waitUntil { try await rig.socket.sentFrames().contains { if case .audio = $0.payload {
            return true
        }; return false } }
        let oldAudio = try #require(try await rig.socket.sentFrames().compactMap { frame -> AudioPayload? in
            if case .audio(let audio) = frame.payload { return audio }; return nil
        }.first)
        await rig.controller.turnOff()
        await rig.controller.turnOn(for: binding)
        rig.controller.reconnect.sendFailed(SocketTestError.closed, audio: oldAudio, binding: binding, store: rig.store)
        #expect(!rig.controller.reconnect.isPending && rig.controller.isListening)
        await rig.close()
    }
}
