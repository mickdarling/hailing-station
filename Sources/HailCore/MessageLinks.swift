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
            let label = visible(String(match.output.1)), target = String(match.output.2)
            if target.utf8.count <= 2_048, let url = webURL(target),
               !label.trimmingCharacters(in: .whitespaces).isEmpty {
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

    /// The links in `segments`, in order, for Copy Link and Share Link.
    public static func links(_ segments: [MessageSegment]) -> [URL] {
        segments.compactMap { if case .link(_, let url) = $0 { url } else { nil } }
    }

    /// The links in `text`, in order.
    public static func links(_ text: String) -> [URL] { links(segments(text)) }

    /// The URL when `string` is an absolute http or https URL with a host, else nil.
    public static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = host(of: url), !host.isEmpty else { return nil }
        return url
    }

    /// The site to show after a link's label, or nil when the label already is the destination: exactly the URL, or
    /// a web URL whose host is identical. A label that merely mentions a host (`paypal.com` linking to `aypal.com`, or
    /// `https://evil.com.paypal.com` linking to `evil.com`) always gets the real host shown beside it.
    public static func destinationHint(label: String, url: URL) -> String? {
        guard let host = host(of: url) else { return nil }
        if label == url.absoluteString { return nil }
        if let shown = webURL(label), let shownHost = Self.host(of: shown),
           shownHost.lowercased() == host.lowercased() { return nil }
        return host
    }

    /// The decoded host, so a percent-encoded host never hides what it spells.
    public static func host(of url: URL) -> String? { url.host(percentEncoded: false) }

    /// Removes bidirectional controls, which could reorder a label to disguise where it leads.
    public static func visible(_ label: String) -> String {
        String(String.UnicodeScalarView(label.unicodeScalars.filter { !bidiControls.contains($0.value) }))
    }

    private static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069
    ]

    /// `[label](target)`; the target may hold one level of balanced parentheses, as Wikipedia links do.
    nonisolated(unsafe) private static let markdownLink = /\[([^\[\]\n]{1,200})\]\(((?:[^()\s]|\([^()\s]*\))+)\)/

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Bare URLs in plain text. The detector also finds schemeless domains and mailto:, which stay plain text.
    private static func bareLinks(_ text: String) -> [MessageSegment] {
        guard !text.isEmpty else { return [] }
        guard let detector else { return [.text(text)] }
        var segments: [MessageSegment] = []
        var cursor = text.startIndex
        for result in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(result.range, in: text), range.lowerBound >= cursor else { continue }
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
