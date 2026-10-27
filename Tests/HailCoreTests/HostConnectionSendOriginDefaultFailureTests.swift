import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite struct SendOriginDefaultFailureTests {
    @Test func rejectedDefaultSendsDoNotAdvanceSequenceOrPublishRefusal() async throws {
        let rig = try await SendOriginRig.ready()
        let stream = UUID()
        try await rig.connection.sendAudio(ambientSegment(stream: stream))
        await #expect(throws: HostConnectionFailure.malformed("ambient sequence must increase")) {
            try await rig.connection.sendAudio(ambientSegment(stream: stream))
        }
        try await rig.connection.sendAudio(ambientSegment(stream: stream, sequence: 1))
        try await rig.process(.error(code: .notAllowed, message: "ambient moved to pad"))
        await #expect(throws: HostConnectionFailure.remote("not_allowed: ambient moved to pad")) {
            try await rig.connection.sendAudio(ambientSegment(stream: stream, sequence: 2))
        }
        let next = UUID()
        await #expect(throws: HostConnectionFailure.malformed("ambient stream must start at sequence 0")) {
            try await rig.connection.sendAudio(ambientSegment(stream: next, sequence: 1))
        }
        try await rig.connection.sendAudio(ambientSegment(stream: next))
        #expect(try await audioFrames(rig.socket).count == 3)
        #expect(await rig.recorder.events.isEmpty)
        #expect(await rig.connection.currentSnapshot().state == .ready)
        await rig.connection.disconnect()
        await #expect(throws: HostConnectionFailure.notReady) {
            try await rig.connection.sendAudio(ambientSegment())
        }
    }
}
