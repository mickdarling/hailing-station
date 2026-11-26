import HailCore
import SwiftUI

typealias StationChatThread = (hostID: HostEndpoint.Identifier, targetID: String)

/// Only a confirmed thread can supply history. Without one the station can still show its reply card.
enum StationConversationContent<History: View>: View {
    case history(History)
    case reply(ReplyPlaybackView)
    case empty

    var body: some View {
        switch self {
        case .history(let history): history
        case .reply(let card): card
        case .empty: EmptyView()
        }
    }
}
