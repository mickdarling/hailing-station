#if STATION_UI_FIXTURES
import Foundation
@testable import HailCore

extension StationTranscriptSeed {
    /// Authored examples from the Astra frames, fixed to 10:42 local time on the qualification day.
    var conversation: [ConversationEntry] {
        let day = Date.now
        let time = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: day) ?? day
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
