import HailCore
import SwiftUI

/// The station chat (#288): what you said and what Haili replied, newest at the bottom, scrolling to each new
/// message. The reply that owns the player shows its status and Pause, Replay and Mute.
struct ConversationChatView: View {
    let allEntries: [ConversationEntry]
    @Bindable var playback: ReplyPlaybackController
    /// Overheard remarks (#398) appear only when the user chose to show them.
    @AppStorage(OverheardSettingsView.showKey) private var showsOverheard = false
    @AppStorage(OverheardSettingsView.whoseKey) private var overheardWhose = "owner"
    /// The message whose text is open for selecting part of it (#412).
    @State private var selecting: ConversationEntry?

    init(entries: [ConversationEntry], playback: ReplyPlaybackController) {
        allEntries = entries
        self.playback = playback
    }

    /// Overheard entries only while shown, and only within the current choice: narrowing to "Just me" hides other
    /// speakers' remarks already received, not just future ones.
    private var entries: [ConversationEntry] {
        allEntries.filter { entry in
            !entry.overheard || (showsOverheard && (overheardWhose == "everyone" || entry.speaker == .you))
        }
    }

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
                    VStack(spacing: 10) { // Not lazy (#428): the log holds at most 200 messages.
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
        // The entry's current text, so a reply still streaming in keeps growing in the sheet.
        .sheet(item: $selecting) { entry in
            SelectableTextSheet(text: allEntries.first { $0.id == entry.id }?.text ?? entry.text)
        }
    }

    /// The reply the player controls now, else the newest reply.
    private var controlledReplyID: String? {
        playback.presentationForControls?.id ?? entries.last { $0.speaker == .haili }?.id
    }

    @ViewBuilder
    private func bubble(_ entry: ConversationEntry) -> some View {
        let (isYou, segments) = (entry.speaker == .you, MessageLinks.segments(entry.text))
        HStack {
            if isYou { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                if entry.overheard {
                    Text(entry.speaker == .you ? "You · not sent" : "\(entry.name ?? "Someone") · not sent")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true) // The bubble's own label says it.
                }
                Text(Self.linked(segments))
                    .foregroundStyle(entry.overheard ? Color.secondary : isYou ? Color.white : Color.primary)
                    .tint(isYou ? Color.white : Color.accentColor)
                    .italic(entry.overheard)
                if entry.speaker == .haili, entry.id == controlledReplyID {
                    replyControls
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                entry.overheard ? AnyShapeStyle(.quinary)
                    : isYou ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            // Copy, Share or select part of any message (#412).
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { StationPlatform.copy(entry.text) }
                ShareLink(item: entry.text)
                Button("Select Text", systemImage: "selection.pin.in.out") { selecting = entry }
                linkActions(segments)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.accessibilityLabel(entry))
            if !isYou { Spacer(minLength: 48) }
        }
    }

    private static func accessibilityLabel(_ entry: ConversationEntry) -> String {
        switch (entry.speaker, entry.overheard) {
        case (.you, false): "You said"
        case (.you, true): "You said, heard but not sent"
        case (.someone, _): "\(entry.name ?? "Someone") said, heard but not sent"
        case (.haili, _): "Haili replied"
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

/// The whole message in a read-only text view, where any part of it can be selected and copied (#412).
private struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding()
                .navigationTitle("Select Text")
                .stationInlineTitle()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
