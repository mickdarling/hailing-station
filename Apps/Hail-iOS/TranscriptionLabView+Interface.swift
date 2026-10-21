import HailCore
import SwiftUI

extension TranscriptionLabView {
    /// Read-only words as they are recognized. The station shows them only while capturing, since each sent request
    /// then appears in the conversation as You (#318, #429); Labs, with no destination, keeps its last transcript.
    @ViewBuilder
    var liveTranscript: some View {
        let capturing = isRecording || isStarting || isFinalizing
        if capturing || (onFinalized == nil && !transcript.isEmpty) {
            Text(transcript.isEmpty ? "Listening…" : transcript)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                .lineLimit(onFinalized == nil ? nil : 4)
                .textSelection(.enabled)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    var transcript: String {
        [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var talkButton: some View {
        Button {
            if isRecording {
                Task { await finish() }
            } else {
                startTask = Task { await begin() }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .frame(width: 82, height: 82)
                    .foregroundStyle(.white)
                    .background(isRecording ? Color.red : Color.accentColor, in: Circle())
                    .shadow(
                        color: (isRecording ? Color.red : Color.accentColor).opacity(0.25),
                        radius: 12,
                        y: 6
                    )
                Text(actionLabel)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(
            isStarting || isFinalizing || isInterrupting || finishTask != nil || interruptTask != nil
                || (!isRecording && pendingSendID != nil)
        )
        .accessibilityIdentifier("station.talk")
        .accessibilityLabel(actionLabel)
        .accessibilityValue(status)
        .accessibilityHint(talkHint)
    }

    var statusRow: some View {
        HStack(spacing: 12) {
            if showsProgress && !reduceMotion {
                ProgressView().accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(status)
                    .font(.subheadline.weight(.semibold))
                if let replyPlaybackStatus {
                    Text("Reply: \(replyStatusLabel(replyPlaybackStatus))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
        .accessibilityValue(replyPlaybackStatus.map { "Reply: \(replyStatusLabel($0))" } ?? "")
        .accessibilityIdentifier("transcription.status")
    }

    var actionLabel: String {
        if isInterrupting { return "Interrupting…" }
        if finishTask != nil { return "Finishing…" }
        if isFinalizing { return "Finalizing…" }
        if isRecording { return "Tap to finish" }
        return isStarting ? "Starting…" : "Tap to talk"
    }

    var showsActivity: Bool {
        isStarting || isRecording || isFinalizing || status == "Sending…"
            || status == "Waiting for reply…"
    }

    var showsProgress: Bool {
        showsActivity || isInterrupting || replyPlaybackStatus.map {
            ["Queued", "Waiting for audio", "Playing", "Replaying"].contains($0)
        } == true
    }

    var talkHint: String {
        guard isRecording else { return "Starts listening." }
        return onFinalized == nil
            ? "Stops listening and finalizes the local transcript."
            : "Stops listening and sends the request."
    }

    @MainActor
    func send(_ text: String, failurePrefix: String) async {
        guard let onFinalized, pendingSendID == nil else { return }
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        let sendID = UUID()
        let destinationAtSend = destinationID
        answeredSendID = nil
        pendingSendID = sendID
        pendingDestinationID = destinationAtSend
        status = "Sending…"
        let paste = attachedPaste
        do {
            try await onFinalized(text, paste)
            // Handed to the Mac with this request (#608). If the Mac refuses it, it comes back attached with the
            // reason (`pasteOffer.refusal`); a paste attached while this one was in flight stays for the next request.
            // A refusal that ended this send already put the paste back, so it is left alone. A reply placed while
            // this send was still going (#636) already ended the wait, but the paste went with the request all the same.
            let answered = answeredEarly(sendID, at: destinationAtSend)
            guard answered || (pendingSendID == sendID && pendingDestinationID == destinationAtSend) else { return }
            if paste != nil, attachedPaste == paste { (attachedPaste, pasteProblem) = (nil, nil) }
            if answered {
                answeredSendID = nil
                return
            }
            if let destinationAtSend, Self.uncorrelatedDestinations.contains(destinationAtSend) {
                clearPendingSend()
                status = "Sent — reply turn unverified"
                return
            }
            status = "Waiting for reply…"
            scheduleReplyTimeout(sendID: sendID, destinationID: destinationAtSend)
        } catch {
            // A reply that arrived during this send (#636) does not hide its failure: the store took that reply back.
            let answered = answeredEarly(sendID, at: destinationAtSend)
            guard answered || (pendingSendID == sendID && pendingDestinationID == destinationAtSend) else { return }
            answeredSendID = nil
            // A paste refused here was never sent, so the destination's reply correlation is unaffected (#608).
            let problem = (error as? PastedDraft.Problem)?.message
            if problem == nil, let destinationAtSend { Self.uncorrelatedDestinations.insert(destinationAtSend) }
            clearPendingSend()
            // A refused paste stays attached, with the reason, so it can be fixed or removed (#608).
            if let problem { pasteProblem = problem }
            status = "\(failurePrefix): \(problem ?? error.localizedDescription)"
        }
    }
    /// A reply that arrived while `sendID` was still going ended its wait (#636), and nothing has happened since on
    /// that destination: no new send, capture or Escape has changed the status from "Reply received".
    @MainActor
    func answeredEarly(_ sendID: UUID, at destination: ConversationDestinationID?) -> Bool {
        answeredSendID == sendID && pendingSendID == nil && destinationID == destination && status == "Reply received"
    }

    @MainActor
    func discardCapture() async {
        capture.stop()
        bufferTask?.cancel()
        bufferTask = nil
        activeUtteranceID = nil
        await transcriber.cancel()
        isRecording = false
    }

    @MainActor
    func quietReplyAudio() async throws {
        status = "Quieting reply audio…"
        try await Task.sleep(for: .milliseconds(200))
    }
}
