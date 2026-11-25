import HailCore
import SwiftUI

extension ConversationChatView {
    @ViewBuilder
    var controlButtons: some View {
        Button {
            playback.togglePause()
        } label: {
            Label(playback.isPaused ? "Resume" : "Pause", systemImage: playback.isPaused ? "play.fill" : "pause.fill")
        }
        Button {
            playback.replayLatest()
        } label: {
            Label("Replay", systemImage: "arrow.counterclockwise")
        }
        .disabled(playback.isCaptureSuppressed)
        Button {
            playback.toggleMute()
        } label: {
            Label(
                playback.isMuted ? "Unmute" : "Mute",
                systemImage: playback.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
            )
        }
    }

    /// Every proactive card's session (#609), or an addressed reply shown in another session's thread (#636).
    static func placedSource(_ entry: ConversationEntry, thread: String?) -> String? {
        if entry.updatePriority != nil { return entry.source.map { "\($0) · Update" } }
        guard let thread, entry.targetID != thread else { return nil }
        return entry.source
    }

    static func accessibilityLabel(_ entry: ConversationEntry, thread: String? = nil) -> String {
        switch (entry.speaker, entry.overheard) {
        case (.you, false): entry.notSent ? "You said, not sent" : "You said"
        case (.you, true): "You said, heard but not sent"
        case (.someone, _): "\(entry.name ?? "Someone") said, heard but not sent"
        // Spoken aloud, or text only (#606); from another session addressed by name, that session (#636).
        case (.haili, _):
            entry.updatePriority != nil ? "\(entry.source ?? "Session") update"
                : "\(placedSource(entry, thread: thread) ?? "Haili") \(entry.spoken ? "said" : "replied")"
        }
    }

    /// A reply's unspoken details under its spoken words (#606), set apart by a divider.
    @ViewBuilder
    func replyDetails(_ entry: ConversationEntry) -> some View {
        if entry.speaker == .haili, let metadata = entry.metadata {
            Divider()
            ReplyMetadataView(source: metadata, blocks: entry.metadataBlocks)
                .tint(Color.accentColor)
        }
    }

    /// Copy Details (the Markdown exactly as received), then Copy Link and Share Link for the spoken text's links and,
    /// as their own group of up to three, the details' links, so neither crowds the other out (#444, #606).
    @ViewBuilder
    func detailsActions(_ entry: ConversationEntry, segments: [MessageSegment]) -> some View {
        if let metadata = entry.metadata {
            Button("Copy Details", systemImage: "doc.plaintext") { StationPlatform.copy(metadata) }
        }
        Self.linkActions(segments)
        Self.linkActions(Self.metadataLinks(entry.metadataBlocks))
    }

    /// The checked web links in a reply's parsed metadata, as link segments for Copy Link and Share Link (#444).
    static func metadataLinks(_ blocks: [MarkdownBlock]) -> [MessageSegment] {
        blocks.flatMap { block -> [AttributedString] in
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
    enum Presentation { case classic, message, details }

    let source: String
    let presentation: Presentation
    @Environment(\.activeStationPalette) private var palette
    private let blocks: [MarkdownBlock]
    @State private var showsRaw = false

    /// `blocks` is the entry's cached parse of `source` (`ConversationEntry.metadataBlocks`).
    init(source: String, blocks: [MarkdownBlock], presentation: Presentation = .classic) {
        self.presentation = presentation
        self.source = source
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .message ? 9 : 6) {
            if showsRaw || blocks.isEmpty {
                Text(verbatim: source)
                    .transcriptBlockFont(.code, base: .footnote.monospaced(), redesigned: presentation != .classic)
                    .textSelection(.enabled)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(block)
                }
            }
            if !blocks.isEmpty, presentation != .message || containsTruncatedTable {
                Button(showsRaw ? "Show Formatted" : "Show Raw Text") { showsRaw.toggle() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .transcriptBlockFont(.metadata, base: .callout, redesigned: presentation != .classic)
        .foregroundStyle(palette.map { AnyShapeStyle($0[presentation == .message ? .textPrimary : .textSecondary]) }
                         ?? AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation == .message ? "Reply text" : "Details, not spoken")
    }

    private var containsTruncatedTable: Bool {
        blocks.contains { if case .table(let table) = $0 { table.truncated } else { false } }
    }

    @ViewBuilder
    private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            if presentation == .classic {
                TranscriptHeading(level: level, text: Self.styled(text))
            } else {
                Text(Self.styled(text, palette: palette))
                    .font(Self.headingFont(level))
                    .foregroundStyle(palette?[.textPrimary] ?? .primary)
                    .accessibilityAddTraits(.isHeader)
            }
        case .paragraph(let text):
            Text(Self.styled(text, palette: palette))
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).monospacedDigit()
                Text(Self.styled(text, palette: palette))
            }
            .padding(.leading, CGFloat(depth) * 14)
            .accessibilityElement(children: .combine)
        case .quote(let text):
            HStack(spacing: 8) {
                if let palette {
                    RoundedRectangle(cornerRadius: 1.5).fill(palette[.separator]).frame(width: 3)
                } else {
                    RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                }
                Text(Self.styled(text, palette: palette))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text, redesigned: presentation != .classic)
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

    /// Links underlined, so they read as links in any tint; the model itself stays UI-framework free. Italics are
    /// reserved for the words Haili spoke (#606), so Markdown emphasis in the details is shown in the primary colour
    /// against their secondary text instead.
    static func styled(_ text: AttributedString, palette: StationPalette? = nil) -> AttributedString {
        var styled = text
        for run in text.runs {
            if run.link != nil { styled[run.range].underlineStyle = .single }
            if palette == nil, var intent = run.inlinePresentationIntent, intent.contains(.emphasized) {
                intent.remove(.emphasized)
                styled[run.range].inlinePresentationIntent = intent.isEmpty ? nil : intent
                styled[run.range].foregroundColor = .primary
            }
        }
        return styled
    }
}
