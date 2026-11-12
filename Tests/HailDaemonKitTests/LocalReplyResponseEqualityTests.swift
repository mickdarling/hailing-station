import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct LocalReplyResponseEqualityTests {
    @Test(arguments: ["absent", "null", "present"])
    func audioPresenceIsPreservedSeparatelyFromValueEquality(kind: String) throws {
        let member: String
        switch kind {
        case "absent": member = ""
        case "null": member = #", "replyAudio": null"#
        default: member = #", "replyAudio": {"skipped": false}"#
        }
        let decoded = try JSONDecoder().decode(LocalReplyResponse.self,
            from: Data("{\"delivered\":0\(member)}".utf8))
        var constructed = LocalReplyResponse(delivered: 0)
        if kind == "present" { constructed.replyAudio = .init() }
        #expect(decoded == constructed)
        #expect(constructed == decoded)
        #expect(decoded.isReplyAudio == (kind != "absent"))
        #expect(!constructed.isReplyAudio)
        #expect(decoded.replyAudio == (kind == "present" ? LocalReplyAudioReport() : nil))
    }

    @Test func dispatchPresenceStillParticipatesInEquality() {
        let reply = LocalReplyResponse(delivered: 0)
        let dispatch = LocalReplyResponse.dispatch(delivered: 0, request: nil)
        #expect(reply.request == dispatch.request)
        #expect(reply != dispatch)
        #expect(dispatch != reply)
    }

    @Test(arguments: ["delivered", "error", "code", "request", "ambient", "update",
                      "progress", "voiceGuards", "replyAudio"])
    func everyOtherFieldStillParticipatesInEquality(field: String) {
        let baseline = LocalReplyResponse(delivered: 0)
        var changed = baseline
        switch field {
        case "delivered": changed.delivered = 1
        case "error": changed.error = "synthetic refusal"
        case "code": changed.code = .replyStopped
        case "request": changed.request = UUID()
        case "ambient": changed.ambient = .init(outcome: .idle)
        case "update": changed.update = .init(outcome: .held)
        case "progress": changed.progress = .init(outcome: "not_enabled")
        case "voiceGuards": changed.voiceGuards = .init(value: .on, enforced: true)
        case "replyAudio": changed.replyAudio = .init()
        default: Issue.record("unknown equality field")
        }
        #expect(baseline == baseline)
        #expect(changed == changed)
        #expect(changed != baseline)
        #expect(baseline != changed)
    }
}
