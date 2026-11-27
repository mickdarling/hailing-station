#if STATION_UI_FIXTURES
import Foundation
@testable import HailCore

extension StationTranscriptSeed {
    func audioProblem(replyID: String) -> String? {
        guard replyID == "reply" else { return nil }
        let status: String
        switch self {
        case .decodeFailed: status = ReplyPlaybackController.audioCouldNotBeDecoded
        case .playbackFailed: status = ReplyPlaybackController.playbackFailed
        case .incompleteAudio: status = ReplyPlaybackController.endedWithoutFinalAudio
        case .discardedAudio: status = ReplyPlaybackController.pausedAudioNotKept
        default: return nil
        }
        return ReplyPlaybackController.audioProblem(status)
    }

    /// Authored examples from the Astra frames, fixed to 10:42 local time on the qualification day.
    var conversation: [ConversationEntry] {
        if self == .scrolling { return (1...20).map(Self.numberedTurn) }
        let day = Date.now
        let time = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: day) ?? day
        if self == .attribution {
            var request = ConversationEntry(id: "request", speaker: .you, text: "Check the list.",
                                            endpointID: "fixture", targetID: Self.session.targetID, date: time)
            request.ambientHeard = true
            var other = ConversationEntry(id: "other", speaker: .someone, text: "Check the list.",
                                          endpointID: "fixture", targetID: Self.session.targetID,
                                          date: time.addingTimeInterval(10))
            other.name = "Speaker B"
            other.overheard = true
            let reply = ConversationEntry(id: "reply", speaker: .haili, text: "The list is ready.",
                                          endpointID: "fixture", targetID: Self.session.targetID,
                                          date: time.addingTimeInterval(20))
            return [request, other, reply]
        }
        if audioProblem(replyID: "reply") != nil {
            // The affected reply precedes a healthy one, so a latest-reply lookup loses the notice.
            return [
                ConversationEntry(id: "reply", speaker: .haili, text: "First reply.",
                                  endpointID: "fixture", targetID: Self.session.targetID, date: time),
                ConversationEntry(id: "heard", speaker: .haili, text: "Next reply.",
                                  endpointID: "fixture", targetID: Self.session.targetID,
                                  date: time.addingTimeInterval(60))
            ]
        }
        var request = ConversationEntry(id: "request", speaker: .you,
                                        text: "Review the release checklist and tell me what still needs attention.",
                                        endpointID: "fixture", targetID: Self.session.targetID, date: time)
        if self == .refused {
            request.notSent = true
            var notice = ConversationEntry(id: "notice", speaker: .haili,
                                           text: "The session already has unsent text in its prompt.",
                                           endpointID: "fixture", targetID: Self.session.targetID, date: time)
            notice.notice = true
            return [request, notice]
        }
        request.transportCompletedTo = .init(hostName: Self.session.hostName, targetName: Self.session.targetName)
        let reply = ConversationEntry(id: "reply", speaker: .haili, text: Self.reply,
                                      endpointID: "fixture", targetID: Self.session.targetID,
                                      date: time.addingTimeInterval(60))
        return [request, reply]
    }

    static func numberedTurn(_ number: Int) -> ConversationEntry {
        let isReply = number.isMultiple(of: 2)
        return ConversationEntry(id: "turn-\(number)", speaker: isReply ? .haili : .you,
                                 text: isReply ? "Reply \(number)." : "Heard \(number).",
                                 endpointID: "fixture", targetID: session.targetID,
                                 date: Date(timeIntervalSince1970: Double(number)))
    }

    static func extendReply(_ reply: inout ConversationEntry) {
        let next = reply.text.components(separatedBy: "\n\n").count
        for number in next..<(next + 16) {
            reply.text += "\n\nStream paragraph \(number)."
        }
    }

    private static let reply = """
        The checklist is ready. **Two items need your attention** before the release:

        - Confirm the supported audio routes on a physical device.
        - Review the reconnect behavior after a call.

        For the audio checks, compare the built-in speaker, headphones and a separate microphone. The output route \
        shown here should match where the reply plays. A headphone name alone does not establish a private \
        coaching route.

        After a call or network interruption, the conversation should stay readable and the selected destination \
        should be confirmed again. Privacy must remain visibly unconfirmed until the Mac reports its state. A \
        reconnect is not proof that a request was delivered.

        The documentation pass is complete. I’ve kept the remaining details in the [release notes](https://example.com/notes).
        """
}
#endif
