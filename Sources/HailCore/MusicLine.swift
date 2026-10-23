import Foundation

/// A transcribed line of music (#823). Whisper wraps sung audio in note marks (`♪♪`, `♪ … ♪`, sometimes `♫`); the
/// conversation shows such a line as music, not as someone speaking.
public enum MusicLine {
    private static let marks: Set<Character> = ["♪", "♫"]

    /// The lyrics when `text` is music: it starts and ends with a note mark, or holds nothing but note marks. The
    /// marks are dropped and the spaces tidied; "" for marks alone. Nil for anything else, including a line that
    /// only starts or only ends with a note.
    public static func lyrics(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last, marks.contains(first), marks.contains(last) else {
            return nil
        }
        let words = trimmed.filter { !marks.contains($0) }.split(whereSeparator: \.isWhitespace)
        return words.joined(separator: " ")
    }

    /// The lyrics when a conversation entry is heard music: only a turn the microphone overheard (#823 review). A
    /// request the owner sent stays their bubble, with its paste and actions, even wrapped in notes; Haili's replies
    /// are never music.
    public static func lyrics(of entry: ConversationEntry) -> String? {
        guard entry.overheard, entry.speaker != .haili else { return nil }
        return lyrics(entry.text)
    }
}
