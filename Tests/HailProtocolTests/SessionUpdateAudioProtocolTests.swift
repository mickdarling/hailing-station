import Foundation
import Testing
@testable import HailProtocol

struct SessionUpdateAudioProtocolTests {
    @Test func cancellationNamesOnlyOneUpdateAndRejectsSmuggledAuthority() throws {
        let control = ControlPayload.sessionUpdateCancel(update: UUID())
        #expect(try JSONDecoder().decode(ControlPayload.self, from: JSONEncoder().encode(control)) == control)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(control)) as? [String: Any])
        object["request"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ControlPayload.self, from: data) }
    }
    @Test func markedAudioRoundTripsAndOrdinaryReplyOmitsMarker() throws {
        let id = UUID()
        let marked = ReplyDescriptor(id: id, hostID: "synthetic-host", targetID: "synthetic:task",
                                     priority: .background, sessionUpdateID: id)
        #expect(try JSONDecoder().decode(ReplyDescriptor.self, from: JSONEncoder().encode(marked)) == marked)
        let ordinary = ReplyDescriptor(id: id, hostID: "synthetic-host", targetID: "synthetic:task")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as? [String: Any])
        #expect(object["update"] == nil)
    }

    @Test func updateCannotClaimARequestOrInterruptOrAnotherIdentity() throws {
        let id = UUID()
        let invalid = [
            ReplyDescriptor(id: id, hostID: "host", targetID: "target", priority: .background,
                            requestID: UUID(), sessionUpdateID: id),
            ReplyDescriptor(id: id, hostID: "host", targetID: "target", priority: .background,
                            interruption: .interrupt, sessionUpdateID: id),
            ReplyDescriptor(id: id, hostID: "host", targetID: "target", sessionUpdateID: id),
            ReplyDescriptor(id: id, hostID: "host", targetID: "target", priority: .background,
                            sessionUpdateID: UUID())
        ]
        for value in invalid {
            let data = try JSONEncoder().encode(value)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ReplyDescriptor.self, from: data) }
        }
    }

    @Test func explicitNullUpdateCannotFallThroughAsOrdinaryAudio() throws {
        let ordinary = ReplyDescriptor(id: UUID(), hostID: "synthetic-host", targetID: "synthetic:task")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as? [String: Any])
        object["update"] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ReplyDescriptor.self, from: data) }
    }
}
