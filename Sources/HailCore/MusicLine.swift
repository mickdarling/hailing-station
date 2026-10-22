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
}
