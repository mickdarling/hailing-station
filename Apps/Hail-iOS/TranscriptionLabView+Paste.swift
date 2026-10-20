import HailCore
import SwiftUI

/// Paste text into the conversation (#608). The system Paste button reads the clipboard only when tapped, so there is
/// no paste-permission prompt and nothing is read in the background. The paste rides with the next spoken request, or
/// goes on its own with Send Paste. Links in it are never opened or fetched. Shown only when the Mac takes pastes.
extension TranscriptionLabView {
    @ViewBuilder
    var pasteControl: some View {
        if acceptsPaste, onFinalized != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let attachedPaste {
                    attachedPasteCard(attachedPaste)
                } else {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in attach(strings.joined(separator: "\n")) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .disabled(pendingSendID != nil)
                    .accessibilityIdentifier("station.paste")
                }
                if let pasteProblem {
                    Text(pasteProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("station.paste.problem")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func attachedPasteCard(_ paste: PastedDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                paste.lineCount == 1 ? "Pasted text" : "Pasted text · \(paste.lineCount) lines",
                systemImage: "doc.on.clipboard"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Text(paste.preview)
                .font(.callout.monospaced())
                .lineLimit(PastedDraft.collapsedLines)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Placeholder wording for Mick to approve (#608).
            Text("Goes with your next request, as pasted text the session treats as data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Send Paste", systemImage: "paperplane.fill") {
                    Task { await send("", failurePrefix: "Send failed") }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("station.paste.send")
                Button("Remove", systemImage: "xmark", role: .destructive) {
                    attachedPaste = nil
                    pasteProblem = nil
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("station.paste.remove")
            }
            .controlSize(.small)
            .disabled(pendingSendID != nil || isRecording || isFinalizing)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pasted text attached")
    }

    @MainActor
    func attach(_ text: String) {
        do {
            attachedPaste = try PastedDraft(text)
            pasteProblem = nil
        } catch {
            pasteProblem = error.message
        }
    }
}
