import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Synthetic fake-host evidence only. A reconnect must never clear another device's privacy park (#945).
@MainActor
@Suite(.serialized) struct AmbientReconnectPrivacyOffTests {
    @Test(arguments: [false, true])
    func knownPrivacyOffNeverSendsPrivacyThroughFirstResumedPCM(mediaOn: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.socket.push(.duckMode(on: false, reason: "device"))
        try await rig.socket.push(.mediaMode(on: mediaOn))
        try await waitUntil { await MainActor.run {
            rig.store.duckMode[rig.endpoint.id]?.on == false
                && rig.store.mediaMode[rig.endpoint.id]?.on == mediaOn
        } }
        let old = try rig.currentBinding()
        let droppedSocket = rig.socket
        let beforeDrop = try await droppedSocket.sentFrames().count
        try await rig.drop()
        try rig.discardWhileWaiting()
        try await rig.reconnect(mode: .mediaMode(on: mediaOn))
        try await waitUntil { try await rig.socket.sentFrames().contains { frame in
            if case .audio = frame.payload { return true }; return false
        } }
        #expect(rig.controller.binding?.connectionGeneration != old.connectionGeneration)
        #expect(rig.controller.isListening && rig.notices.map(\.outcome) == [.applied])
        let frames = try await rig.socket.sentFrames()
        let gapFrames = try await droppedSocket.sentFrames().dropFirst(beforeDrop)
        #expect((Array(gapFrames) + frames).allSatisfy { frame in
            if case .control(.setPrivacy) = frame.payload { return false }; return true
        })
        let firstAudio = try #require(frames.compactMap { frame -> AudioPayload? in
            if case .audio(let audio) = frame.payload { return audio }; return nil
        }.first)
        #expect(firstAudio.isResume && firstAudio.sequence == 0)
        await rig.close()
    }
}
