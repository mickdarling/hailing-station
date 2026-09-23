import SwiftUI

extension TranscriptionLabView {
    @ViewBuilder
    var transcriptSurface: some View {
        Group {
            if isRecording || isStarting || isFinalizing {
                ScrollView {
                    Text(transcript.isEmpty ? "Listening…" : transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            } else {
                TextEditor(text: $finalText)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if finalText.isEmpty {
                            Text("Your last request will appear here.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Last transcript")
            }
        }
        .frame(
            minHeight: horizontalSizeClass == .regular ? 240 : 150,
            idealHeight: horizontalSizeClass == .regular ? 320 : 190,
            maxHeight: horizontalSizeClass == .regular ? 420 : 240
        )
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    @ViewBuilder
    var transcriptActions: some View {
        HStack(spacing: 8) {
            if showsActivity {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status)
        .accessibilityIdentifier("transcription.status")

        HStack {
            if onFinalized != nil {
                Button("Send edited correction") {
                    let correction = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await send(correction, failurePrefix: "Correction failed")
                    }
                }
                .disabled(
                    showsActivity || isInterrupting || interruptTask != nil || finishTask != nil || finalText.isEmpty
                )
            }

            Button("Clear") {
                finalText = ""
                volatileText = ""
            }
            .disabled(isRecording || transcript.isEmpty)
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
    }

    var transcript: String {
        [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
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
        let replyAtSend = latestReplyID
        pendingSendID = sendID
        pendingDestinationID = destinationAtSend
        status = "Sending…"
        do {
            try await onFinalized(text)
            guard pendingSendID == sendID, pendingDestinationID == destinationAtSend else { return }
            if latestReplyID == replyAtSend {
                status = "Waiting for reply…"
                scheduleReplyTimeout(sendID: sendID, destinationID: destinationAtSend)
            }
        } catch {
            guard pendingSendID == sendID, pendingDestinationID == destinationAtSend else { return }
            clearPendingSend()
            status = "\(failurePrefix): \(error.localizedDescription)"
        }
    }

    @MainActor
    func noteReplyArrival(previous: String?, current: String?) {
        guard current != nil, current != previous,
              pendingDestinationID == destinationID,
              status == "Sending…" || status == "Waiting for reply…" else { return }
        clearPendingSend()
        status = "Reply received"
    }

    @MainActor
    func noteDestinationChange(
        previous: ConversationDestinationID?, current: ConversationDestinationID?
    ) {
        guard current != previous else { return }
        clearPendingSend()
        guard !isStarting, !isRecording, !isFinalizing, !isInterrupting else { return }
        status = "Ready"
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
