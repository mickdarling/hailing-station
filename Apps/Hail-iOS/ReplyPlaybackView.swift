import HailCore
import SwiftUI

struct ReplyPlaybackView: View {
    let reply: ReplyPresentation
    @Bindable var playback: ReplyPlaybackController

    var body: some View {
        GroupBox("Latest reply") {
            VStack(alignment: .leading, spacing: 10) {
                Text(reply.transcript ?? "Receiving spoken reply…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(reply.transcript == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                Text(playback.status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(playback.isPaused ? "Resume" : "Pause") { playback.togglePause() }
                    Button("Replay") { playback.replayLatest() }
                    Button(playback.isMuted ? "Unmute" : "Mute") { playback.toggleMute() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
