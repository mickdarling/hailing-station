import HailCore
import SwiftUI

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
    let audioProblem: String?
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
                    if let audioProblem {
                        Label(audioProblem, systemImage: "speaker.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat.reply.audio-problem")
                    }
                    actions
                } else if case .transportCompleted(let destination) = turn.delivery {
                    Text("\(destination.hostName) · \(destination.targetName)")
                        .font(.caption2).foregroundStyle(palette[.textSecondary])
                        .accessibilityHidden(true) // The Sent chip reads the full destination.
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let chip = turn.delivery.chip {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { badges(chip) }.fixedSize()
                    VStack(alignment: .leading, spacing: 4) { badges(chip) }
                }
            } else {
                Text(turn.speaker).font(.caption.weight(.semibold))
                if let session = turn.session {
                    Text(session).font(.caption2.weight(.semibold)).foregroundStyle(palette[.textSecondary])
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(palette[.surface], in: .rect(cornerRadius: 5))
                }
            }
            Spacer(minLength: 4)
            Text(ChatTimestamps.time(entry.date)).font(.caption2).foregroundStyle(palette[.textSecondary])
        }
        .accessibilityElement(children: turn.delivery == .reply ? .combine : .contain)
        .accessibilityAddTraits(turn.delivery == .reply ? .isHeader : [])
        .accessibilityIdentifier("station.transcript.heading")
    }

    @ViewBuilder private func badges(_ chip: (title: String, accessibilityLabel: String)) -> some View {
        Text(verbatim: turn.speaker)
            .font(.caption.weight(.semibold)).foregroundStyle(palette[.textPrimary])
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(palette[.surface], in: Capsule())
            .accessibilityLabel("Speaker: \(turn.speaker).")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("station.transcript.speaker")
        Text(chip.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(palette[turn.delivery.isHeldWarning ? .stateWarning : .textPrimary])
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(palette[turn.delivery.isHeldWarning ? .warningSurface : .surface], in: Capsule())
            .accessibilityLabel(chip.accessibilityLabel)
            .accessibilityIdentifier("station.transcript.dispatch")
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
