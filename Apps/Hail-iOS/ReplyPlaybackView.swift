import HailCore
import SwiftUI

struct ReplyPlaybackView: View {
    let reply: ReplyPresentation
    @Bindable var playback: ReplyPlaybackController

    private var displayedReply: ReplyPresentation { playback.presentationForDisplay ?? reply }

    private var controlReply: ReplyPresentation { playback.presentationForControls ?? reply }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if playback.displayDiffersFromControls {
                    Label(latestReplyLabel, systemImage: "text.bubble")
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel(latestReplyLabel)
                }
                // A long reply scrolls inside the card, so the one-screen iPad station never overflows (#288).
                ViewThatFits(in: .vertical) {
                    transcript
                    ScrollView { transcript }
                }

                HStack {
                    Label(controlStatus, systemImage: playbackStatusImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(controlReply.host) · \(controlReply.target)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { playbackControls }
                    VStack(spacing: 10) { playbackControls }
                }
                .buttonStyle(.bordered)
            }
        } label: {
            Label("Haili replied", systemImage: "bubble.left.and.waveform.fill")
                .font(.headline)
        }
        .accessibilityElement(children: .contain)
    }

    private var transcript: some View {
        Text(displayedReply.transcript ?? "Receiving spoken reply…")
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(displayedReply.transcript == nil ? .secondary : .primary)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var playbackControls: some View {
        Button {
            playback.togglePause()
        } label: {
            Label(playback.isPaused ? "Resume" : "Pause", systemImage: playback.isPaused ? "play.fill" : "pause.fill")
                .frame(maxWidth: .infinity)
        }
        Button {
            playback.replayLatest()
        } label: {
            Label("Replay", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .disabled(playback.isCaptureSuppressed)
        Button {
            playback.toggleMute()
        } label: {
            Label(
                playback.isMuted ? "Unmute" : "Mute",
                systemImage: playback.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            )
                .frame(maxWidth: .infinity)
        }
    }

    private var latestReplyLabel: String {
        "Latest reply · \(displayedReply.host) · \(displayedReply.target) · \(playback.status(for: displayedReply))"
    }

    private var controlStatus: String {
        let role = playback.isReplyAudioOutputBusy ? "Now playing" : "Playback"
        return "\(role) · \(playback.statusForControls)"
    }

    private var playbackStatusImage: String {
        if playback.isMuted { return "speaker.slash.fill" }
        if playback.isPaused { return "pause.circle.fill" }
        return "waveform.circle.fill"
    }
}
