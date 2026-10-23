import HailCore
import SwiftUI

extension ConversationChatView {
    /// On a reply whose audio did not play (#825, #822): the text above is all there is, and this says so. VoiceOver
    /// hears it through the station's deferred reply announcements, which wait for a safe moment (#86).
    @ViewBuilder
    func audioProblemNote(_ entry: ConversationEntry) -> some View {
        if entry.speaker == .haili, let problem = playback.audioProblem(replyID: entry.id) {
            Label(problem, systemImage: "speaker.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("chat.reply.audio-problem")
        }
    }
}
