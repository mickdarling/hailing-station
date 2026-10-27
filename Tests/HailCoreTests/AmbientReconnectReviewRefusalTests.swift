import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectReviewRefusalTests {
    @Test func asynchronousWireRefusalMustNotAnnounceSuccessfulRestore() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        rig.wrapReconnect = { ReviewerWireRefusal(base: $0) }
        try await rig.reconnect()
        try await waitUntil { try await MainActor.run {
            try rig.capture.yield(sineBuffer())
            return !rig.controller.isOn && rig.released == 1
        } }
        #expect(rig.controller.handoff == .movedAway(to: "pad"))
        #expect(rig.notices.last?.outcome != .applied,
                "Socket send success announced resumed listening before the asynchronous host moved-away refusal")
        #expect(rig.notices.last?.reason == .movedAway)
        await rig.close()
    }

    @Test func refusalAfterAppliedReplacesNoticeWithoutWaitingForMorePCM() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        try await rig.reconnect()
        #expect(rig.notices.last?.outcome == .applied)
        let noticeID = rig.controller.reconnect.notice?.id
        try await rig.socket.push(.error(code: .notAllowed, message: "ambient moved to pad"))
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.controller.handoff == .movedAway(to: "pad"))
        #expect(rig.controller.reconnect.notice?.id == noticeID)
        #expect(rig.notices.last?.outcome == .failed && rig.notices.last?.reason == .movedAway)
        let count = try await rig.socket.sentFrames().count
        try await rig.feed()
        #expect(try await rig.socket.sentFrames().count == count)
        await rig.close()
    }
}
private actor ReviewerWireRefusal: WebSocketTransport {
    let base: ScriptedSocket
    var refused = false
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        await base.send(data)
        if case .audio = frame.payload, !refused {
            refused = true
            try await base.push(.error(code: .notAllowed, message: "ambient moved to pad"))
        }
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}
