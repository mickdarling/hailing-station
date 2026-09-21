import AVFAudio
import HailCore
import Speech
import SwiftUI

/// Temporary real-device surface for proving DJI/built-in capture through SpeechAnalyzer before terminal styling.
@available(iOS 26.0, *)
struct TranscriptionLabView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let destinationLabel: String?
    let onFinalized: (@MainActor (String) async throws -> Void)?
    let onEscape: (@MainActor () async throws -> Void)?

    @State var capture: any AudioCapturing
    @State var transcriber: any Transcriber

    @State var isRecording = false
    @State var finalText = ""
    @State var volatileText = ""
    @State var status = "Ready"
    @State var isStarting = false
    @State var isFinalizing = false
    @State var hasReceivedAudio = false
    @State var startTask: Task<Void, Never>?
    @State var bufferTask: Task<Void, Never>?

    init(
        audioSession: any AudioSessionDiagnosticsProviding,
        capture: any AudioCapturing = AVAudioEngineCapture(),
        transcriber: any Transcriber = SpeechAnalyzerTranscriber(),
        destinationLabel: String? = nil,
        onFinalized: (@MainActor (String) async throws -> Void)? = nil,
        onEscape: (@MainActor () async throws -> Void)? = nil
    ) {
        self.audioSession = audioSession
        self.destinationLabel = destinationLabel
        self.onFinalized = onFinalized
        self.onEscape = onEscape
        _capture = State(initialValue: capture)
        _transcriber = State(initialValue: transcriber)
    }

    var body: some View {
        VStack(spacing: 20) {
            if let destinationLabel {
                Label(destinationLabel, systemImage: "desktopcomputer")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isRecording || isStarting || isFinalizing {
                ScrollView {
                    Text(transcript.isEmpty ? "Listening…" : transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            } else {
                TextEditor(text: $finalText)
                    .overlay(alignment: .topLeading) {
                        if finalText.isEmpty {
                            Text("Your transcript will appear here.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Last transcript")
            }

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("transcription.status")

            Button(actionLabel) {
                if isRecording {
                    Task { await finish() }
                } else {
                    startTask = Task { await begin() }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isStarting || isFinalizing)

            if let onEscape {
                Button(role: .destructive) {
                    Task {
                        do {
                            try await onEscape()
                            status = "Escape sent"
                        } catch {
                            status = "Escape failed: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    Label("Escape", systemImage: "xmark.octagon.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isRecording || isStarting || isFinalizing)
            }

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
        .padding()
        .navigationTitle("Live transcription")
        .task { await observeResults() }
        .onDisappear {
            startTask?.cancel()
            Task { await finish(force: true) }
        }
    }

    private var transcript: String {
        [finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var actionLabel: String {
        if isFinalizing { return "Finalizing…" }
        if isRecording { return "Tap to finish" }
        return isStarting ? "Starting…" : "Tap to talk"
    }
}
