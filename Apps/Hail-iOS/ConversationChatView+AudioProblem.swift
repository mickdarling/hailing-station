import HailCore
import SwiftUI

extension ConversationChatView {
    /// On a reply whose audio did not play (#825, #822): the text above is all of it, and this says so.
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

/// Announces once when a reply's audio does not play (#825, #822), for VoiceOver, so a lost reply is never silent.
/// The audible cue for everyone comes with the shared announcer (S4b).
@MainActor
final class ReplyAudioProblemAnnouncer {
    private var announced: Set<String> = []
    private let announce: @MainActor (String) -> Void

    init(announce: @escaping @MainActor (String) -> Void = StationPlatform.announce) {
        self.announce = announce
    }

    func watch(_ playback: ReplyPlaybackController) {
        let problems = withObservationTracking { playback.audioProblems } onChange: { [weak self, weak playback] in
            Task { @MainActor in
                guard let self, let playback else { return }
                self.watch(playback)
            }
        }
        for (id, problem) in problems where announced.insert(id).inserted {
            announce("Reply \(problem.lowercased()). Its text is on screen.")
        }
    }
}
