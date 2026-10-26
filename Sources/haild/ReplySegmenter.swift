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

    /// Uses the same environment tuning mechanism as HAILD_REPLY_PACING.
    /// Invalid overrides warn without content and keep that limit’s default.
    static func load(environment: [String: String]) throws -> Self {
        try Self(
            maxSentences: value("HAILD_REPLY_SEGMENT_MAX_SENTENCES", in: environment,
                                fallback: defaultMaxSentences, bounds: sentenceBounds),
            maxWords: value("HAILD_REPLY_SEGMENT_MAX_WORDS", in: environment,
                            fallback: defaultMaxWords, bounds: wordBounds)
        )
    }

    private static func value(
        _ key: String, in environment: [String: String], fallback: Int, bounds: ClosedRange<Int>
    ) -> Int {
        guard let raw = environment[key] else { return fallback }
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(raw), bounds.contains(value) else {
            FileHandle.standardError.write(Data("haild: invalid \(key); using default\n".utf8))
            return fallback
        }
        return value
    }
}

/// Deterministic, content-free segmentation, with no I/O. Keeps original spelling and internal whitespace.
/// CJK terminators and !/? end even without spaces, retaining closing quotes/brackets; newlines end items.
/// Periods inside a token (URLs, paths, decimals, versions) never end a sentence. Common titles, e.g./i.e.,
/// initials and dotted initialisms are protected; ellipses end a sentence only before an uppercase word.
/// An oversized sentence prefers its last comma, semicolon, colon or em dash within the word limit.
struct ReplySegmenter {
    let configuration: ReplySegmentation

    func segments(_ text: String) -> [String] {
        let sentences = sentenceRanges(in: text)
        var pieces: [Substring] = []
        var current = text[text.startIndex..<text.startIndex]
        var sentenceCount = 0, wordCount = 0
        for sentence in sentences {
            for piece in bounded(sentence) {
                let count = piece.split(whereSeparator: \.isWhitespace).count
                let combined = wordCount + count - (current.isEmpty || current.endIndex != piece.startIndex ? 0 : 1)
                if !current.isEmpty, sentenceCount == configuration.maxSentences
                    || combined > configuration.maxWords {
                    pieces.append(current)
                    current = text[piece.startIndex..<piece.startIndex]
                    sentenceCount = 0
                    wordCount = 0
                }
                wordCount += count - (current.isEmpty || current.endIndex != piece.startIndex ? 0 : 1)
                current = text[(current.isEmpty ? piece.startIndex : current.startIndex)..<piece.endIndex]
                sentenceCount += 1
            }
        }
        if !current.isEmpty { pieces.append(current) }
        guard !pieces.isEmpty else { return [] }
        guard pieces.count > 1 else { return [text] }
        pieces[0] = text[text.startIndex..<pieces[0].endIndex]
        let last = pieces.count - 1
        pieces[last] = text[pieces[last].startIndex..<text.endIndex]
        return pieces.map(String.init)
    }

    private func sentenceRanges(in text: String) -> [Substring] {
        let words = text.split(whereSeparator: \.isWhitespace).flatMap(sentenceTokens)
        var ranges: [Substring] = []
        var start = 0
        for index in words.indices {
            let next = index + 1
            let newline = next < words.count
                && text[words[index].endIndex..<words[next].startIndex].contains(where: \.isNewline)
            if next == words.count || newline || endsSentence(words[index], next: words[next]) {
                ranges.append(text[words[start].startIndex..<words[index].endIndex])
                start = next
            }
        }
        return ranges
    }

    /// Split only unconditional terminators inside a whitespace token; periods retain the lexical rules below.
    private func sentenceTokens(_ word: Substring) -> [Substring] {
        var tokens: [Substring] = []
        var start = word.startIndex, end = start
        var terminated = false
        for index in word.indices {
            let character = word[index]
            if terminated, !Self.terminators.contains(character), !Self.closers.contains(character) {
                tokens.append(word[start..<index])
                start = index
                terminated = false
            }
            if Self.terminators.contains(character) { terminated = true }
            end = word.index(after: index)
        }
        if start < end { tokens.append(word[start..<end]) }
        return tokens
    }

    private func bounded(_ sentence: Substring) -> [Substring] {
        let words = sentence.split(whereSeparator: \.isWhitespace)
        var start = 0
        var pieces: [Substring] = []
        while words.count - start > configuration.maxWords {
            let limit = start + configuration.maxWords
            let clause = (start..<limit).last { index in
                let token = unquoted(words[index])
                return token.last.map { ",;:—".contains($0) } ?? false
            }
            let end = clause.map { $0 + 1 } ?? limit
            pieces.append(sentence[words[start].startIndex..<words[end - 1].endIndex])
            start = end
        }
        pieces.append(sentence[words[start].startIndex..<sentence.endIndex])
        return pieces
    }

    private func unquoted(_ word: Substring) -> Substring {
        var token = word.drop(while: { "\"'“‘([{".contains($0) })
        var end = token.endIndex
        while end > token.startIndex {
            let previous = token.index(before: end)
            guard Self.closers.contains(token[previous]) else { break }
            end = previous
        }
        token = token[..<end]
        return token
    }

    private func endsSentence(_ word: Substring, next: Substring) -> Bool {
        let token = unquoted(word)
        guard let last = token.last else { return false }
        if Self.terminators.contains(last) { return true }
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

    private static let terminators = "!?。！？．"
    private static let closers = "\"'”’)]}」』）］｝】〉》〞"
    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.", "prof.", "sr.", "jr.", "vs.", "etc.", "st."
    ]
}
