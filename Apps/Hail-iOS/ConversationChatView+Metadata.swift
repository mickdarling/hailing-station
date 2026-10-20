import HailCore
import SwiftUI

extension ConversationChatView {
    static func accessibilityLabel(_ entry: ConversationEntry) -> String {
        switch (entry.speaker, entry.overheard) {
        case (.you, false): "You said"
        case (.you, true): "You said, heard but not sent"
        case (.someone, _): "\(entry.name ?? "Someone") said, heard but not sent"
        case (.haili, _): entry.spoken ? "Haili said" : "Haili replied" // spoken aloud, or text only (#606)
        }
    }

    /// A reply's unspoken details under its spoken words (#606), set apart by a divider.
    @ViewBuilder
    func replyDetails(_ entry: ConversationEntry) -> some View {
        if entry.speaker == .haili, let metadata = entry.metadata {
            Divider()
            ReplyMetadataView(source: metadata)
                .tint(Color.accentColor)
        }
    }

    /// Copy Details (the Markdown exactly as received), then Copy Link and Share Link for the spoken text's links and
    /// the details' links, in that order (#444, #606).
    @ViewBuilder
    func detailsActions(_ entry: ConversationEntry, segments: [MessageSegment]) -> some View {
        if let metadata = entry.metadata {
            Button("Copy Details", systemImage: "doc.plaintext") { UIPasteboard.general.string = metadata }
        }
        linkActions(segments + Self.metadataLinks(entry.metadata))
    }

    /// The checked web links in a reply's metadata, as link segments, so Copy Link and Share Link (#444) offer them
    /// after the spoken text's own.
    static func metadataLinks(_ metadata: String?) -> [MessageSegment] {
        guard let metadata else { return [] }
        return MessageMarkdown.blocks(metadata).flatMap { block -> [AttributedString] in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(_, _, let text): [text]
            case .table(let table): table.header + table.rows.flatMap { $0 }
            case .code, .rule: []
            }
        }.flatMap { text in
            text.runs.compactMap { run in
                run.link.map { MessageSegment.link(label: String(text[run.range].characters), url: $0) }
            }
        }
    }
}

/// A reply's unspoken metadata (#606): links, references, file paths, tables and status, rendered from the shared
/// `MessageMarkdown` model under the reply's spoken words. Secondary styling, system text styles (Dynamic Type) and
/// semantic colours (Dark Mode). Blocks are read in order by VoiceOver; headings are headers. "Show Raw Text" shows the
/// source exactly as received, so nothing the model could not place is ever hidden.
struct ReplyMetadataView: View {
    let source: String
    private let blocks: [MarkdownBlock]
    @State private var showsRaw = false

    init(source: String) {
        self.source = source
        blocks = MessageMarkdown.blocks(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsRaw || blocks.isEmpty {
                Text(verbatim: source)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(block)
                }
            }
            if !blocks.isEmpty {
                Button(showsRaw ? "Show Formatted" : "Show Raw Text") { showsRaw.toggle() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details, not spoken")
    }

    @ViewBuilder
    private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.styled(text))
                .font(Self.headingFont(level))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.styled(text))
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).monospacedDigit()
                Text(Self.styled(text))
            }
            .padding(.leading, CGFloat(depth) * 14)
            .accessibilityElement(children: .combine)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                Text(Self.styled(text)).italic()
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider()
        }
    }

    /// Text styles, so headings scale with Dynamic Type; a level 1 heading stays below the chat's own headline size.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .headline
        case 2: .subheadline.weight(.semibold)
        default: .footnote.weight(.semibold)
        }
    }

    /// Links underlined, so they read as links in any tint; the model itself stays UI-framework free.
    static func styled(_ text: AttributedString) -> AttributedString {
        var styled = text
        for range in text.runs.filter({ $0.link != nil }).map(\.range) {
            styled[range].underlineStyle = .single
        }
        return styled
    }
}
