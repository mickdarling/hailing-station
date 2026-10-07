import HailCore
import SwiftUI

/// The station chat (#288): what you said and what Haili replied, newest at the bottom, scrolling to each new
/// message. The reply that owns the player shows its status and Pause, Replay and Mute.
struct ConversationChatView: View {
    let entries: [ConversationEntry]
    @Bindable var playback: ReplyPlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer(minLength: 8)
                // The player may be speaking a reply from another destination: its controls stay reachable here.
                if playback.presentationForControls != nil, !entries.contains(where: { $0.id == controlledReplyID }) {
                    replyControls
                }
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if entries.isEmpty {
                            Text("Tap to talk. What you say and Haili's replies appear here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(entries) { entry in
                            bubble(entry).id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom)
                .onChange(of: entries) { _, current in
                    guard let last = current.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("station.chat")
    }

    /// The reply the player controls now, else the newest reply.
    private var controlledReplyID: String? {
        playback.presentationForControls?.id ?? entries.last { $0.speaker == .haili }?.id
    }

    @ViewBuilder
    private func bubble(_ entry: ConversationEntry) -> some View {
        let isYou = entry.speaker == .you
        HStack {
            if isYou { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.text)
                    .foregroundStyle(isYou ? Color.white : Color.primary)
                    .textSelection(.enabled)
                if !isYou, entry.id == controlledReplyID {
                    replyControls
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isYou ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isYou ? "You said" : "Haili replied")
            if !isYou { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        Button {
            playback.togglePause()
        } label: {
            Label(playback.isPaused ? "Resume" : "Pause", systemImage: playback.isPaused ? "play.fill" : "pause.fill")
        }
        Button {
            playback.replayLatest()
        } label: {
            Label("Replay", systemImage: "arrow.counterclockwise")
        }
        .disabled(playback.isCaptureSuppressed)
        Button {
            playback.toggleMute()
        } label: {
            Label(
                playback.isMuted ? "Unmute" : "Mute",
                systemImage: playback.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            )
        }
    }

    private var replyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(playback.statusForControls, systemImage: "waveform.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // Titles where they fit, icons in a narrow column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { controlButtons }.labelStyle(.titleAndIcon)
                HStack(spacing: 8) { controlButtons }.labelStyle(.iconOnly)
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
