import Foundation

/// Spoken reply tuning. Defaults are v1, pending Mick: two sentences and thirty whitespace-delimited words.
/// Bounds keep each piece useful while allowing a caller to tune it without imposing a total speech cap.
struct ReplySegmentation: Equatable, Sendable {
    static let defaultMaxSentences = 2
    static let defaultMaxWords = 30
    static let sentenceBounds = 1...20
    static let wordBounds = 1...300
    let maxSentences: Int
    let maxWords: Int

    init(maxSentences: Int = defaultMaxSentences, maxWords: Int = defaultMaxWords) throws {
        guard Self.sentenceBounds.contains(maxSentences), Self.wordBounds.contains(maxWords) else {
            throw ReplyCommandError.invalid("reply segmentation limits out of bounds (sentences 1...20, words 1...300)")
        }
        self.maxSentences = maxSentences
        self.maxWords = maxWords
    }

    /// Uses the same environment tuning mechanism as HAILD_REPLY_PACING; invalid overrides fail before publication.
    static func load(environment: [String: String]) throws -> Self {
        try Self(
            maxSentences: value("HAILD_REPLY_SEGMENT_MAX_SENTENCES", in: environment, fallback: defaultMaxSentences),
            maxWords: value("HAILD_REPLY_SEGMENT_MAX_WORDS", in: environment, fallback: defaultMaxWords)
        )
    }

    private static func value(_ key: String, in environment: [String: String], fallback: Int) throws -> Int {
        guard let raw = environment[key] else { return fallback }
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw) else {
            throw ReplyCommandError.invalid("invalid reply segmentation setting: \(key)")
        }
        return value
    }
}

/// Deterministic, content-free segmentation, with no I/O. Keeps original spelling and internal whitespace.
/// Sentence ends are ., ? and ! (including closing quotes/brackets), or a newline between words/list items.
/// Periods inside a token (URLs, paths, decimals, versions) never end a sentence. Common titles, e.g./i.e.,
/// initials and dotted initialisms are protected; ellipses end a sentence only before an uppercase word.
/// An oversized sentence prefers its last comma, semicolon, colon or em dash within the word limit.
struct ReplySegmenter {
    let configuration: ReplySegmentation

    func segments(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let sentences = sentenceRanges(words, in: text)
        var pieces: [Range<Int>] = []
        var current = 0..<0, sentenceCount = 0
        for sentence in sentences {
            for piece in bounded(sentence, words: words) {
                if !current.isEmpty, sentenceCount == configuration.maxSentences
                    || current.count + piece.count > configuration.maxWords {
                    pieces.append(current)
                    current = piece.lowerBound..<piece.lowerBound
                    sentenceCount = 0
                }
                current = current.lowerBound..<piece.upperBound
                sentenceCount += 1
            }
        }
        if !current.isEmpty { pieces.append(current) }
        guard pieces.count > 1 else { return [text] }
        return pieces.enumerated().map { index, piece in
            let start = index == 0 ? text.startIndex : words[piece.lowerBound].startIndex
            let end = index == pieces.count - 1 ? text.endIndex : words[piece.upperBound - 1].endIndex
            return String(text[start..<end])
        }
    }

    private func sentenceRanges(_ words: [Substring], in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for index in words.indices {
            let next = index + 1
            let newline = next < words.count
                && text[words[index].endIndex..<words[next].startIndex].contains(where: \.isNewline)
            if next == words.count || newline || endsSentence(words[index], next: words[next]) {
                ranges.append(start..<next)
                start = next
            }
        }
        return ranges
    }

    private func bounded(_ sentence: Range<Int>, words: [Substring]) -> [Range<Int>] {
        var start = sentence.lowerBound
        var pieces: [Range<Int>] = []
        while sentence.upperBound - start > configuration.maxWords {
            let limit = start + configuration.maxWords
            let clause = (start..<limit).last { index in
                let token = unquoted(words[index])
                return token.last.map { ",;:—".contains($0) } ?? false
            }
            let end = clause.map { $0 + 1 } ?? limit
            pieces.append(start..<end)
            start = end
        }
        pieces.append(start..<sentence.upperBound)
        return pieces
    }

    private func unquoted(_ word: Substring) -> Substring {
        var token = word.drop(while: { "\"'“‘([{".contains($0) })
        while let last = token.last, "\"'”’)]}".contains(last) { token = token.dropLast() }
        return token
    }

    private func endsSentence(_ word: Substring, next: Substring) -> Bool {
        let token = unquoted(word)
        guard let last = token.last else { return false }
        if last == "?" || last == "!" { return true }
        if last == "…" { return unquoted(next).first?.isUppercase == true }
        guard last == "." else { return false }
        if token.hasSuffix("...") { return unquoted(next).first?.isUppercase == true }
        let lower = token.lowercased()
        if Self.abbreviations.contains(lower) { return false }
        let parts = token.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        if parts.allSatisfy({ $0.count == 1 && $0.first?.isLetter == true }) { return false }
        // A numbered list marker belongs to its item, not to a sentence of its own.
        return !token.dropLast().allSatisfy(\.isNumber)
    }

    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.", "prof.", "sr.", "jr.", "vs.", "etc.", "st."
    ]
}
