import HailCore
import SwiftUI

extension ConversationChatView {
    /// Message text with tappable web links, opened only on tap: Safari, or the owning app by universal link.
    /// A labelled link also names its site, so the destination is never hidden behind the label (#444).
    static func linked(_ text: String) -> AttributedString {
        MessageLinks.segments(text).reduce(into: AttributedString()) { result, segment in
            switch segment {
            case .text(let plain): result += AttributedString(plain)
            case .link(let label, let url):
                var link = AttributedString(label)
                link.link = url
                link.underlineStyle = .single
                result += link
                if let host = url.host(), label != url.absoluteString, !label.localizedCaseInsensitiveContains(host) {
                    result += AttributedString(" (\(host))")
                }
            }
        }
    }

    /// Copy Link and Share Link for the first few links in a message, in the long-press menu (#412, #444).
    @ViewBuilder
    func linkActions(_ text: String) -> some View {
        ForEach(Array(MessageLinks.links(text).prefix(3).enumerated()), id: \.offset) { _, url in
            Button("Copy Link: \(url.host() ?? url.absoluteString)", systemImage: "link") {
                UIPasteboard.general.url = url
            }
            ShareLink(item: url) { Label("Share Link", systemImage: "square.and.arrow.up.on.square") }
        }
    }
}
