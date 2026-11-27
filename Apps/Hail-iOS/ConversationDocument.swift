import HailCore
import SwiftUI

/// S3c Astra deviations (#1340).
/// Audio played strip omitted: per-row replay cannot be truthful until #1351 is fixed; playback stays in the dock. Tracked in #1340.
/// Text size control (Aa) omitted: the redesigned transcript uses base text styles; tracked in #1356.
struct ConversationDocument: View {
    let allEntries: [ConversationEntry]
    let hostName: String?
    let sessions: [String: String]
    let audioProblem: @MainActor (String) -> String?
    let copy: (String) -> Void
    @Environment(\.stationPalette) private var palette
    @State private var links = MessageSegmentCache()
    @State private var sheet: TranscriptSheet?
    @State private var atBottom = true
    @State private var readingID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading(allEntries)
                if allEntries.isEmpty {
                    Text("Tap to talk. What you say and Haili’s replies appear here.")
                        .foregroundStyle(palette[.textSecondary])
                }
                turns(allEntries)
            }
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition(id: $readingID)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(atBottom ? .bottom : nil, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 2
        } action: { _, bottom in atBottom = bottom }
        .tint(palette[.brand])
        .foregroundStyle(palette[.textPrimary], palette[.textSecondary])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("station.chat")
        .sheet(item: $sheet) { selection in sheetContent(selection) }
    }

    private func heading(_ entries: [ConversationEntry]) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text("Speak naturally. Keep the details here.").font(.caption).foregroundStyle(palette[.textSecondary])
            }
            Spacer()
            let replies = entries.filter { $0.speaker == .haili && !$0.notice }
            if !replies.isEmpty {
                Menu {
                    ForEach(replies.reversed()) { entry in
                        Button { readingID = entry.id } label: {
                            Text("\(entry.source ?? sessions[entry.targetID] ?? entry.targetID) · "
                                 + ChatTimestamps.header(for: entry.date))
                        }
                    }
                } label: {
                    Label("Reply history", systemImage: "list.bullet").font(.caption)
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }

    private func turns(_ entries: [ConversationEntry]) -> some View {
        let starts = ChatTimestamps.groupStarts(entries.map(\.date))
        return VStack(alignment: .leading, spacing: 19) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                VStack(alignment: .leading, spacing: 17) {
                    if starts.contains(index) { divider(entry.date) }
                    TranscriptEntryView(entry: entry, turn: turn(entry), segments: links.segments(for: entry),
                                        audioProblem: audioProblem(entry.id),
                                        copy: copy, present: { [sheet = $sheet] in sheet.wrappedValue = $0 })
                }
                .id(entry.id)
            }
        }
        .scrollTargetLayout()
    }

    private func divider(_ date: Date) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(palette[.separator]).frame(height: 1)
            Text(ChatTimestamps.header(for: date, separator: " · "))
                .font(.caption2).foregroundStyle(palette[.textSecondary]).fixedSize()
            Rectangle().fill(palette[.separator]).frame(height: 1)
        }.accessibilityAddTraits(.isHeader)
    }

    private func turn(_ entry: ConversationEntry) -> TranscriptTurn {
        TranscriptTurn(entry: entry, sessionName: sessions[entry.targetID])
    }

    private func sheetContent(_ selection: TranscriptSheet) -> some View {
        NavigationStack {
            Group {
                if let entry = allEntries.first(where: { $0.id == selection.entryID }) {
                    switch selection {
                    case .details: deliveryDetails(entry)
                    case .selection: SelectableText(text: ConversationChatView.copyable(entry)).padding()
                            .navigationTitle("Select Text")
                    }
                } else { Text("This turn is no longer in the conversation.") }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
        .frame(minWidth: 280, minHeight: 240)
        .presentationDetents([.medium, .large])
    }

    private func deliveryDetails(_ entry: ConversationEntry) -> some View {
        Form {
            if let hostName { LabeledContent("Mac", value: hostName) }
            LabeledContent("Session", value: entry.source ?? sessions[entry.targetID] ?? entry.targetID)
            LabeledContent("Reply time", value: ChatTimestamps.header(for: entry.date))
        }
        .formStyle(.grouped)
        .navigationTitle("Delivery details")
        .accessibilityIdentifier("station.transcript.delivery")
    }
}
