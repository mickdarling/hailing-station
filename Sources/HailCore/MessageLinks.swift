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

    /// One distinct, readable name per link for Copy Link and Share Link (and VoiceOver): the host, or, when several
    /// links share it, the host and a short path ("github.com/…/pull/438"), numbered if those still repeat.
    public static func titles(_ urls: [URL]) -> [String] {
        let hosts = urls.map { host(of: $0) ?? $0.absoluteString }
        let named = zip(urls, hosts).map { url, host in
            hosts.filter { $0 == host }.count > 1 ? withPath(host, url) : host
        }
        return named.enumerated().map { index, name in
            let earlier = named[..<index].filter { $0 == name }.count
            return earlier == 0 && named.filter({ $0 == name }).count == 1 ? name : "\(name) (\(earlier + 1))"
        }
    }

    /// The whole host, never shortened, then the last two path components with the rest elided; only the path part
    /// is truncated (to 32 characters), so a long host can't push its real domain out of the name.
    private static func withPath(_ host: String, _ url: URL) -> String {
        let parts = url.path(percentEncoded: true).split(separator: "/")
        guard !parts.isEmpty else { return host }
        var tail = parts.suffix(2).joined(separator: "/")
        if parts.count > 2 { tail = "…/" + tail }
        if tail.count > 32 { tail = String(tail.prefix(31)) + "…" }
        return "\(host)/\(tail)"
    }

    /// The links in `text`, in order.
    public static func links(_ text: String) -> [URL] { links(segments(text)) }

    /// The URL when `string` is an absolute http or https URL with a plain host and no user or password, else nil.
    /// Userinfo is never linked: in `https://paypal.com@evil.com` the site is evil.com. Nor is a host with percent
    /// escapes or any character outside letters, digits, "." and "-" (or an IPv6 address): Foundation keeps such
    /// hosts unencoded, so `%D0%B0pple.com` or `paypal.com%2F.evil.com` would otherwise name a different-looking site.
    public static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = host(of: url), isPlainHost(host),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// ASCII letters, digits, "." and "-", or an IPv6 address; so a shown host is plain ASCII or `xn--` punycode.
    private static func isPlainHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        if host.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }) { return true }
        return host.contains(":") && host.unicodeScalars.allSatisfy { ipv6Characters.contains($0) }
    }

    private static let hostCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    private static let ipv6Characters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")

    /// The site to show after a link's label, or nil when the label already is the destination: exactly the URL, or
    /// a web URL whose host is identical. A label that merely mentions a host (`paypal.com` linking to `aypal.com`, or
    /// `https://evil.com.paypal.com` linking to `evil.com`) always gets the real host shown beside it.
    /// An internationalized host (punycode `xn--`, or non-ASCII in the label) or an "@" in the label always shows the
    /// host, in its ASCII (punycode) form, since either can make one site look like another.
    public static func destinationHint(label: String, url: URL) -> String? {
        guard let host = host(of: url) else { return nil }
        let internationalized = host.split(separator: ".").contains { $0.lowercased().hasPrefix("xn--") }
            || !label.unicodeScalars.allSatisfy(\.isASCII)
        if internationalized || label.contains("@") { return host }
        if label == url.absoluteString { return nil }
        if let shown = webURL(label), let shownHost = Self.host(of: shown),
           shownHost.lowercased() == host.lowercased() { return nil }
        return host
    }

    /// The host exactly as written in the URL, never decoded: `webURL` admits only plain ASCII hosts.
    public static func host(of url: URL) -> String? { url.host(percentEncoded: true) }

    /// Removes Unicode format characters (category Cf: bidirectional controls, zero-width characters, soft hyphens,
    /// byte-order marks), which could reorder or hide parts of a label to disguise where it leads.
    public static func visible(_ label: String) -> String {
        String(String.UnicodeScalarView(label.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

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
