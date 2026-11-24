/// Keeps interpolated Swift code and skips comments, string text and extended regex literals.
/// Tokens retain their source positions.
struct StopReferenceLexer {
    enum LexicalError: Error {
        case unterminatedComment, unterminatedString, unterminatedInterpolation, unterminatedRegex
    }

    private var rest: Substring
    private var result: [Substring] = []

    init(_ source: String) {
        rest = source[...]
    }

    mutating func tokens() throws -> [Substring] {
        try readCode()
        return result
    }

    private mutating func readCode(interpolation: Bool = false) throws {
        var depth = 0
        while let char = rest.first {
            if char.isWhitespace {
                rest = rest.drop(while: \.isWhitespace)
            } else if take("//") {
                rest = rest.drop { !$0.isNewline }
            } else if take("/*") {
                try skipBlockComment()
            } else if char == "\"" || char == "#" {
                try readLiteralOrHashes()
            } else if char == "`" {
                rest.removeFirst() // Escaped identifiers have the same spelling as their unescaped form.
            } else {
                let token = readToken()
                result.append(token)
                if interpolation && token == ")" && depth == 0 { return }
                if token == "(" { depth += 1 }
                if token == ")" { depth -= 1 }
            }
        }
        if interpolation { throw LexicalError.unterminatedInterpolation }
    }

    private mutating func readToken() -> Substring {
        let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        let token = word.isEmpty ? rest.prefix(1) : word
        rest = rest[token.endIndex...]
        return token
    }

    private mutating func skipBlockComment() throws {
        var depth = 1
        while !rest.isEmpty {
            if take("/*") {
                depth += 1
            } else if take("*/") {
                depth -= 1
                if depth == 0 { return }
            } else {
                rest.removeFirst()
            }
        }
        throw LexicalError.unterminatedComment
    }

    private mutating func readLiteralOrHashes() throws {
        let hashes = rest.prefix { $0 == "#" }
        rest = rest[hashes.endIndex...]
        if !hashes.isEmpty, take("/") {
            result.append(hashes)
            try skipExtendedRegex(closing: "/" + String(hashes))
            return
        }
        guard rest.first == "\"" else {
            result.append(hashes)
            return
        }
        result.append(rest.prefix(1))
        let quote = take("\"\"\"") ? "\"\"\"" : String(rest.removeFirst())
        let close = quote + String(hashes)
        let escape = "\\" + String(hashes)
        while !rest.isEmpty {
            let delimiter = rest.prefix(1)
            if take(close) {
                result.append(delimiter)
                return
            }
            if take(escape) {
                if rest.first == "(" {
                    result.append(rest.prefix(1))
                    rest.removeFirst()
                    try readCode(interpolation: true)
                } else if !rest.isEmpty {
                    rest.removeFirst()
                }
            } else {
                rest.removeFirst()
            }
        }
        throw LexicalError.unterminatedString
    }

    private mutating func skipExtendedRegex(closing: String) throws {
        while !rest.isEmpty {
            if take(closing) { return }
            if rest.removeFirst() == "\\" { rest = rest.dropFirst() }
        }
        throw LexicalError.unterminatedRegex
    }

    private mutating func take(_ prefix: String) -> Bool {
        guard rest.hasPrefix(prefix) else { return false }
        rest.removeFirst(prefix.count)
        return true
    }
}
