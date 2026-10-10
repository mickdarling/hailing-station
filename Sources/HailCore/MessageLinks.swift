public import Foundation

/// A run of message text: plain, or a link that opens only when tapped (#444).
public enum MessageSegment: Equatable, Sendable {
    case text(String)
    case link(label: String, url: URL)
}

/// Splits conversation text into plain runs and web links (#444). Agents may write `[label](url)`; bare URLs are
/// detected as well. Only http and https become links: any other scheme (javascript:, file:, app schemes) stays
/// plain text, so a message can never open something other than a web page or its universal link.
public enum MessageLinks {
    public static func segments(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var plain = ""
        var rest = Substring(text)
        while let match = rest.firstMatch(of: markdownLink) {
            plain += rest[rest.startIndex..<match.range.lowerBound]
            let (label, target) = (String(match.output.1), String(match.output.2))
            if let url = webURL(target), !label.trimmingCharacters(in: .whitespaces).isEmpty {
                segments += bareLinks(plain)
                plain = ""
                segments.append(.link(label: label, url: url))
            } else {
                plain += rest[match.range] // Not a web link: shown exactly as written.
            }
            rest = rest[match.range.upperBound...]
        }
        segments += bareLinks(plain + rest)
        return segments
    }

    /// The links in `text`, in order, for Copy Link.
    public static func links(_ text: String) -> [URL] {
        segments(text).compactMap { if case .link(_, let url) = $0 { url } else { nil } }
    }

    /// The URL when `string` is an absolute http or https URL with a host, else nil.
    public static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    nonisolated(unsafe) private static let markdownLink = /\[([^\[\]\n]{1,200})\]\(([^()\s]{1,2048})\)/

    /// Bare URLs in plain text. The detector also finds schemeless domains and mailto:, which stay plain text.
    private static func bareLinks(_ text: String) -> [MessageSegment] {
        guard !text.isEmpty else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return [.text(text)]
        }
        var segments: [MessageSegment] = []
        var cursor = text.startIndex
        for result in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(result.range, in: text) else { continue }
            let written = trimmed(text[range])
            guard written.lowercased().hasPrefix("http://") || written.lowercased().hasPrefix("https://"),
                  let url = webURL(String(written)) else { continue }
            if cursor < range.lowerBound { segments.append(.text(String(text[cursor..<range.lowerBound]))) }
            segments.append(.link(label: String(written), url: url))
            cursor = written.endIndex
        }
        if cursor < text.endIndex { segments.append(.text(String(text[cursor...]))) }
        return segments
    }

    /// Drops sentence punctuation after a URL, and a closing parenthesis it did not open.
    private static func trimmed(_ url: Substring) -> Substring {
        var url = url
        while let last = url.last, ".,;:!?'\"".contains(last) || (last == ")" && !closesOwnParenthesis(url)) {
            url = url.dropLast()
        }
        return url
    }

    /// True when the final ")" closes a "(" inside the URL, as in Wikipedia links.
    private static func closesOwnParenthesis(_ url: Substring) -> Bool {
        url.filter { $0 == "(" }.count >= url.filter { $0 == ")" }.count
    }
}
