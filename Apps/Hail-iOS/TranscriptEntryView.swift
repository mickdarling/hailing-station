import HailCore
import SwiftUI

private extension TranscriptTurn.Delivery {
    var title: String? {
        switch self {
        case .transportCompleted(let destination): "Sent to \(destination.hostName) · \(destination.targetName)"
        case .notSent: "Not sent"
        case .overheard: "Heard · not sent"
        case .reply, .unknown: nil
        }
    }
}

enum TranscriptSheet: Identifiable {
    case details(String), selection(String)

    var id: String {
        switch self {
        case .details(let id): "details-\(id)"
        case .selection(let id): "selection-\(id)"
        }
    }

    var entryID: String {
        switch self {
        case .details(let id), .selection(let id): id
        }
    }
}

struct TranscriptEntryView: View {
    let entry: ConversationEntry
    let turn: TranscriptTurn
    let segments: [MessageSegment]
    let copy: (String) -> Void
    let present: (TranscriptSheet) -> Void
    @Environment(\.stationPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if entry.notice {
                TranscriptWarning(title: "Request not sent", detail: entry.text)
            } else if let lyrics = MusicLine.lyrics(of: entry) {
                Label(lyrics.isEmpty ? "Music" : lyrics, systemImage: "music.note")
                    .font(.body).italic().foregroundStyle(palette[.textSecondary])
            } else {
                heading
                content
                if turn.delivery == .reply {
                    actions
                } else if let receipt = turn.delivery.title {
                    Label(receipt, systemImage: receiptSymbol).font(.caption2)
                        .foregroundStyle(palette[turn.delivery == .notSent ? .stateWarning : .textSecondary])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    private var receiptSymbol: String {
        switch turn.delivery {
        case .transportCompleted: "checkmark"
        case .overheard: "ear"
        default: "exclamationmark.circle"
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(turn.speaker).font(.caption.weight(.semibold))
            if let session = turn.session {
                Text(session).font(.caption2.weight(.semibold)).foregroundStyle(palette[.textSecondary])
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(palette[.surface], in: .rect(cornerRadius: 5))
            }
            Spacer(minLength: 4)
            Text(ChatTimestamps.time(entry.date)).font(.caption2).foregroundStyle(palette[.textSecondary])
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var content: some View {
        if !entry.text.isEmpty {
            if turn.delivery == .reply {
                TranscriptReplyText(text: entry.text).equatable()
            } else {
                Text(ConversationChatView.linked(segments))
                    .font(.body)
                    .foregroundStyle(palette[entry.overheard || entry.notSent ? .textSecondary : .textPrimary])
                    .italic(entry.overheard).textSelection(.enabled)
                    .accessibilityIdentifier("station.transcript.body")
            }
        }
        if let pasted = entry.pasted {
            TranscriptPasteBlock(text: pasted, state: entry.pasteState, font: .callout.monospaced())
        }
        if let metadata = entry.metadata {
            Divider()
            ReplyMetadataView(source: metadata, blocks: entry.metadataBlocks, presentation: .details)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Copy", systemImage: "doc.on.doc") { copy(ConversationChatView.copyable(entry)) }
            Button { present(.details(entry.id)) } label: {
                HStack(spacing: 5) { Text("Delivery details"); Image(systemName: "chevron.right") }
            }
            .accessibilityIdentifier("station.transcript.details")
        }
        .buttonStyle(.plain).font(.caption).foregroundStyle(palette[.textSecondary])
        .padding(.vertical, 4)
    }

    @ViewBuilder private var menu: some View {
        let text = ConversationChatView.copyable(entry)
        Button("Copy", systemImage: "doc.on.doc") { copy(text) }
        ShareLink(item: text)
        Button("Select Text", systemImage: "selection.pin.in.out") { present(.selection(entry.id)) }
        if let pasted = entry.pasted { Button("Copy Pasted Text") { copy(pasted) } }
        if let metadata = entry.metadata { Button("Copy Details") { copy(metadata) } }
        ConversationChatView.linkActions(segments)
        ConversationChatView.linkActions(ConversationChatView.metadataLinks(entry.metadataBlocks))
    }
}

/// A rail tick or another row's streaming text must not repeatedly parse an unchanged reply.
private struct TranscriptReplyText: View, Equatable {
    let text: String

    var body: some View {
        ReplyMetadataView(source: text, blocks: MessageMarkdown.blocks(text), presentation: .message)
            .textSelection(.enabled)
            .accessibilityIdentifier("station.transcript.reply")
    }
}

/// A system notice is separate from both speakers' turns.
struct TranscriptWarning: View {
    let title: String
    let detail: String
    @Environment(\.stationPalette) private var palette

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette[.textPrimary])
                Text(verbatim: detail).font(.body)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(palette[.stateWarning])
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette[.warningSurface], in: .rect(cornerRadius: 7))
    }
}
