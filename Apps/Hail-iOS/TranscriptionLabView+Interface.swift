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
        .disabled(isStarting || isFinalizing || isInterrupting || finishTask != nil)
        .accessibilityIdentifier("station.talk")
        .accessibilityLabel(actionLabel)
        .accessibilityValue(status)
        .accessibilityHint(talkHint)
    }

    @ViewBuilder
    var transcriptActions: some View {
        Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("transcription.status")

        HStack {
            if let onFinalized {
                Button("Send edited correction") {
                    let correction = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        do {
                            try await onFinalized(correction)
                            status = "Correction sent"
                        } catch {
                            status = "Correction failed: \(error.localizedDescription)"
                        }
                    }
                }
                .disabled(isRecording || isStarting || isFinalizing || finalText.isEmpty)
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

    var talkHint: String {
        guard isRecording else { return "Starts listening." }
        return onFinalized == nil
            ? "Stops listening and finalizes the local transcript."
            : "Stops listening and sends the request."
    }
}
