public import Foundation

extension MessageMarkdown {
    private static let inlineOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// One block's inline Markdown (bold, italic, strikethrough, inline code, links) as a safe `AttributedString`
    /// (#606), with the same link rules as plain messages (#444):
    /// - a link stays a link only when `MessageLinks.webURL` accepts it (http or https, plain host, no userinfo). Any
    ///   other target is shown as text with the target beside it, so its destination is never hidden;
    /// - a label that is not its own address is followed by its real site, from `MessageLinks.destinationHint`;
    /// - format characters are removed from link labels, as `MessageLinks.visible` does;
    /// - an image is never loaded: it becomes a link named "Image: <alt>" that opens only when tapped;
    /// - raw HTML is kept as the literal text it is, never interpreted;
    /// - bare web addresses in plain runs become links, as in plain messages.
    /// If Foundation cannot parse the text, it is returned as plain text with bare links.
    public static func inline(_ markdown: String) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: markdown, options: inlineOptions) else {
            return linkedPlain(markdown, attributes: AttributeContainer())
        }
        var result = AttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var attributes = AttributeContainer()
            var intent = run.inlinePresentationIntent ?? []
            // A raw HTML tag is shown as the literal text it is: never interpreted, and nothing in it is linked.
            let literal = intent.contains(.inlineHTML) || intent.contains(.code)
            intent.remove(.inlineHTML)
            if !intent.isEmpty { attributes.inlinePresentationIntent = intent }
            if let image = run.imageURL {
                result += link(label: "Image: \(text.isEmpty ? "untitled" : text)", target: image, attributes)
            } else if let target = run.link {
                result += link(label: text, target: target, attributes)
            } else if literal {
                result += AttributedString(text, attributes: attributes)
            } else {
                result += linkedPlain(text, attributes: attributes)
            }
        }
        return result
    }

    private static func link(label: String, target: URL, _ attributes: AttributeContainer) -> AttributedString {
        let label = MessageLinks.visible(label)
        guard let url = MessageLinks.webURL(target.absoluteString), !label.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            // Not a web link: the label, then where it pointed, as plain text that opens nothing.
            return AttributedString("\(label) (\(target.absoluteString.prefix(200)))", attributes: attributes)
        }
        var linked = AttributedString(label, attributes: attributes)
        linked.link = url // The client styles links (underline, tint); this model stays UI-framework free.
        if let hint = MessageLinks.destinationHint(label: label, url: url) {
            linked += AttributedString(" (\(hint))", attributes: attributes)
        }
        return linked
    }

    private static func linkedPlain(_ text: String, attributes: AttributeContainer) -> AttributedString {
        MessageLinks.segments(text).reduce(into: AttributedString()) { result, segment in
            switch segment {
            case .text(let plain): result += AttributedString(plain, attributes: attributes)
            case .link(let label, let url): result += link(label: label, target: url, attributes)
            }
        }
    }
}
