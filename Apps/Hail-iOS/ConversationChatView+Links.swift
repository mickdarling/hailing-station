import HailCore
import SwiftUI

extension ConversationChatView {
    /// Message text with tappable web links, opened only on tap: Safari, or the owning app by universal link.
    /// A link whose label isn't its own address also names its real site, so the destination is never hidden (#444).
    static func linked(_ segments: [MessageSegment]) -> AttributedString {
        segments.reduce(into: AttributedString()) { result, segment in
            switch segment {
            case .text(let plain): result += AttributedString(plain)
            case .link(let label, let url):
                var link = AttributedString(label)
                link.link = url
                link.underlineStyle = .single
                result += link
                if let host = MessageLinks.destinationHint(label: label, url: url) {
                    result += AttributedString(" (\(host))")
                }
            }
        }
    }

    /// Copy Link and Share Link for the first few links in a message, in the long-press menu (#412, #444).
    @ViewBuilder
    func linkActions(_ segments: [MessageSegment]) -> some View {
        let urls = Array(MessageLinks.links(segments).prefix(3))
        ForEach(Array(zip(urls, MessageLinks.titles(urls)).enumerated()), id: \.offset) { _, link in
            let (url, site) = link
            Button("Copy Link: \(site)", systemImage: "link") {
                UIPasteboard.general.url = url
            }
            ShareLink(item: url) { Label("Share Link: \(site)", systemImage: "square.and.arrow.up.on.square") }
        }
    }
}
