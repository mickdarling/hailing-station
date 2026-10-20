import HailCore
import SwiftUI

extension ConversationChatView {
    /// The message's own words and, on the device's own sent turn, its paste (#608). Only `noteSent` records a paste,
    /// so a host frame never renders one.
    @ViewBuilder
    func messageContent(_ entry: ConversationEntry, segments: [MessageSegment], isYou: Bool) -> some View {
        if !entry.text.isEmpty {
            Text(Self.linked(segments))
                .foregroundStyle(entry.overheard ? Color.secondary : isYou ? Color.white : Color.primary)
                .tint(isYou ? Color.white : Color.accentColor)
                .italic(entry.overheard)
        }
        if isYou, !entry.overheard, let pasted = entry.pasted {
            PastedBlockView(text: pasted)
        }
    }

    @ViewBuilder
    func pasteActions(_ entry: ConversationEntry) -> some View {
        if let pasted = entry.pasted {
            Button("Copy Pasted Text", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = pasted }
        }
    }

    static func youSaid(_ entry: ConversationEntry) -> String {
        guard entry.pasted != nil else { return "You said" }
        return entry.text.isEmpty ? "You pasted" : "You said, with a paste"
    }
}

/// A paste the user sent (#608), shown in its own block inside their message, apart from what they said. A long paste
/// starts collapsed to its first lines with Show All. Plain text: links in it are not made tappable, previewed or
/// fetched.
struct PastedBlockView: View {
    let text: String
    @State private var expanded = false

    private var isLong: Bool { PastedDraft.isLong(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                PastedDraft.lineCount(text) == 1 ? "Pasted" : "Pasted · \(PastedDraft.lineCount(text)) lines",
                systemImage: "doc.on.clipboard"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(verbatim: expanded || !isLong ? text : PastedDraft.preview(text))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button(expanded ? "Show Less" : "Show All") {
                    withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier("station.chat.paste.toggle")
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pasted text")
        .accessibilityIdentifier("station.chat.paste")
    }
}
