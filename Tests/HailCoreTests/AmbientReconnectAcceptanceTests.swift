import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAcceptanceTests {
    @Test(arguments: [true, false])
    func refusalAfterAcceptanceRoundTripUsesOrdinaryStopPath(movedAway: Bool) async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        let id = rig.controller.reconnect.notice?.id
        let nonce = try await rig.waitForAcceptancePing()
        // The pong and refusal arrive consecutively. Do not wait for the polling confirmation task to wake.
        try await rig.socket.push(.pong(nonce: nonce))
        let message = movedAway ? "ambient moved to pad" : "ambient busy elsewhere"
        try await rig.socket.push(.error(code: .notAllowed, message: message))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.map(\.id) == [id])
        #expect(rig.notices.last?.outcome == .applied)
        #expect(!rig.controller.reconnect.replacedAppliedNotice)
        if movedAway {
            #expect(rig.controller.handoff == .movedAway(to: "pad") && rig.unexpected.isEmpty)
        } else {
            #expect(rig.controller.handoff == nil && rig.unexpected.count == 1)
            #expect(rig.unexpected.first?.contains(message) == true)
        }
        await rig.close()
    }

    @Test func differentStreamOrGenerationCannotReplaceTheRestoresNotice() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        let proof = try #require(rig.controller.reconnect.acceptance)
        let binding = try rig.currentBinding()
        let other = AmbientAudioBinding(hostID: binding.hostID, targetID: binding.targetID,
                                       connectionGeneration: UUID(), selection: binding.selection)
        rig.controller.reconnect.refused(reason: .startFailed, streamID: UUID(), binding: binding)
        rig.controller.reconnect.refused(reason: .startFailed, streamID: proof.streamID, binding: other)
        #expect(rig.notices.map(\.outcome) == [.applied])
        #expect(!rig.controller.reconnect.replacedAppliedNotice)
        await rig.close()
    }
}

extension AmbientReconnectRig {
    @discardableResult
    func waitForAcceptancePing() async throws -> String {
        let proof = try #require(controller.reconnect.acceptance)
        try await waitUntil {
            try await self.socket.sentFrames().contains { $0.payload == .control(.ping(nonce: proof.nonce)) }
        }
        let frames = try await socket.sentFrames()
        let audioIndex = try #require(frames.firstIndex { frame in
            if case .audio(let audio) = frame.payload { return audio.isResume && audio.streamID == proof.streamID }
            return false
        })
        let pingIndex = try #require(frames.firstIndex { $0.payload == .control(.ping(nonce: proof.nonce)) })
        #expect(audioIndex < pingIndex)
        return proof.nonce
    }
}
