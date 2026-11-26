import HailCore
import SwiftUI

extension RootView {
    func chatSurface<History: View>(
        @ViewBuilder history: (StationChatThread) -> History
    ) -> StationConversationContent<History> {
        if let thread = chatThread { return .history(history(thread)) }
        if let reply = playback.latest { return .reply(ReplyPlaybackView(reply: reply, playback: playback)) }
        return .empty
    }

    var stationDocument: StationConversationContent<ConversationDocument> {
        chatSurface { thread in
            let host = connections.snapshots[thread.hostID]
            let entries = connections.conversation.entries(endpointID: thread.hostID, targetID: thread.targetID,
                                                          addressed: true)
            let visible = entries.filter {
                !$0.overheard || (settingsShowOverheard && (settingsWhoseOverheard == "everyone" || $0.speaker == .you))
            }
            ConversationDocument(allEntries: visible, hostName: host?.endpoint.name ?? thread.hostID,
                                 sessions: (host?.targets ?? []).reduce(into: [:]) { $0[$1.id] = $1.name },
                                 audioProblem: { [weak playback] in playback?.audioProblem(replyID: $0) },
                                 copy: StationPlatform.copy)
        }
    }
}
