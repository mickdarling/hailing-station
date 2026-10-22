import HailCore
import SwiftUI

extension ConversationChatView {
    /// One conversation entry: a refusal notice, heard music (#823), or a message bubble.
    @ViewBuilder
    func entryRow<Notice: View, Bubble: View>(
        _ entry: ConversationEntry, notice: (ConversationEntry) -> Notice, bubble: (ConversationEntry) -> Bubble
    ) -> some View {
        if entry.notice {
            notice(entry)
        } else if let lyrics = Self.music(entry) {
            musicLine(entry, lyrics: lyrics)
        } else {
            bubble(entry)
        }
    }

    /// The lyrics when a heard line is music (#823); never for Haili's replies.
    static func music(_ entry: ConversationEntry) -> String? {
        entry.speaker == .haili ? nil : MusicLine.lyrics(entry.text)
    }

    /// Music the microphone heard (#823): a dimmed line with a note, the lyrics in italics, and no speaker, since
    /// nobody said it. It follows the same overheard setting as every other heard line, and can still be copied.
    func musicLine(_ entry: ConversationEntry, lyrics: String) -> some View {
        Label {
            Text(lyrics.isEmpty ? "Music" : lyrics)
                .italic()
        } icon: {
            Image(systemName: "music.note")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { StationPlatform.copy(lyrics.isEmpty ? entry.text : lyrics) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.musicLabel(lyrics, at: entry.date))
    }

    /// "Music: <lyrics>, 9:41 PM", or "Music, 9:41 PM" for note marks alone.
    static func musicLabel(_ lyrics: String, at date: Date) -> String {
        "\(lyrics.isEmpty ? "Music" : "Music: \(lyrics)"), \(ChatTimestamps.time(date))"
    }
}
