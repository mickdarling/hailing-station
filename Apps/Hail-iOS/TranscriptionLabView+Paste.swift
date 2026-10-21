import HailCore
import SwiftUI

/// What the station knows about pasting to its destination (#608): whether it takes pastes, and the latest paste its
/// Mac refused (a new value puts that paste back with the reason).
struct PasteOffer: Equatable {
    var accepts = false
    var refusal: PasteRefusal?
}

/// How the station handled the Mac's paste refusals (#639 review).
struct PasteRefusalHandling {
    /// The refusal already handled, so the same one never puts a paste back twice.
    var handledID: UUID?
    /// A status set without being spoken, because the shared request refusal already announced the event once.
    var quietStatus: String?
}

/// Paste text into the conversation (#608). The system Paste button reads the clipboard only when tapped, so there is
/// no paste-permission prompt and nothing is read in the background. The paste rides with the next spoken request, or
/// goes on its own with Send Paste. Links in it are never opened or fetched. Paste is offered only when the destination
/// takes pastes, but an attached paste always stays visible with Remove, and it never follows a destination change.
/// When the Mac refuses a sent paste, it comes back attached with the reason.
extension TranscriptionLabView {
    var pasteControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachedPaste {
                attachedPasteCard(attachedPaste)
            } else if pasteOffer.accepts, onFinalized != nil {
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
        .onChange(of: destinationID) { _, _ in
            attachedPaste = nil
            pasteProblem = nil
        }
        .onChange(of: pasteOffer.refusal) { _, refusal in
            // Only a new refusal of the request this station is waiting on, to this destination: an old one seen
            // again after switching away and back never brings a paste back.
            guard let refusal, refusal.id != pasteRefusalHandling.handledID, pendingSendID != nil,
                  pendingDestinationID == destinationID,
                  let restored = try? PastedDraft(refusal.pasted) else { return }
            pasteRefusalHandling.handledID = refusal.id
            attachedPaste = restored
            pasteProblem = PastedDraft.Problem.refusedByHost(refusal.message).message
            // That request is over: no reply will come for it, so its reply wait ends and the status leaves
            // "Waiting for reply". The new status is not spoken: the shared request refusal (#692) already adds
            // the one line and the one announcement.
            clearPendingSend()
            if status != "Ready" { (pasteRefusalHandling.quietStatus, status) = ("Ready", "Ready") }
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

    /// Speaks a status change, except the one status a host paste refusal set quietly.
    @MainActor
    func announceStatusUnlessQuiet(_ current: String) {
        guard current != pasteRefusalHandling.quietStatus else {
            pasteRefusalHandling.quietStatus = nil
            return
        }
        announceStatusIfNeeded(current)
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
