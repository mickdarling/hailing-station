import AVFAudio
import HailCore
import Speech
import SwiftUI

/// Temporary real-device surface for proving DJI/built-in capture through SpeechAnalyzer before terminal styling.
@available(iOS 26.0, *)
struct TranscriptionLabView: View {
    let audioSession: any AudioSessionDiagnosticsProviding

    @State private var capture: any AudioCapturing
    @State private var transcriber: any Transcriber

    @State private var isRecording = false
    @State private var finalText = ""
    @State private var volatileText = ""
    @State private var status = "Ready"
    @State private var isStarting = false
    @State private var isFinalizing = false
    @State private var hasReceivedAudio = false
    @State private var startTask: Task<Void, Never>?
    @State private var bufferTask: Task<Void, Never>?

    init(
        audioSession: any AudioSessionDiagnosticsProviding,
        capture: any AudioCapturing = AVAudioEngineCapture(),
        transcriber: any Transcriber = SpeechAnalyzerTranscriber()
    ) {
        self.audioSession = audioSession
        _capture = State(initialValue: capture)
        _transcriber = State(initialValue: transcriber)
    }

    var body: some View {
        VStack(spacing: 20) {
            ScrollView {
                Text(transcript.isEmpty ? "Your transcript will appear here." : transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)

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

    @MainActor
    private func begin() async {
        guard !isRecording, !isStarting, !isFinalizing else { return }
        isStarting = true
        hasReceivedAudio = false
        defer {
            isStarting = false
            startTask = nil
        }
        status = "Requesting microphone and speech access…"
        guard await requestHailPermissions() else {
            status = "Microphone and speech recognition permissions are required."
            return
        }

        do {
            try Task.checkCancellation()
            status = "Preparing on-device speech model…"
            try await audioSession.activate()
            try await transcriber.start()
            try Task.checkCancellation()
            let buffers = try capture.start()
            isRecording = true
            status = "Listening"
            bufferTask = Task {
                do {
                    for await buffer in buffers {
                        markAudioReceived()
                        try await transcriber.consume(buffer)
                    }
                } catch {
                    await fail("Capture failed: \(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            await cleanUp()
            status = "Ready"
        } catch {
            await cleanUp()
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func finish(force: Bool = false) async {
        guard !isFinalizing, force || isRecording || bufferTask != nil else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        status = "Finalizing…"
        await cleanUp()
        status = "Ready"
    }

    @MainActor
    private func fail(_ message: String) async {
        await cleanUp(waitForBuffer: false)
        status = message
    }

    @MainActor
    private func cleanUp(waitForBuffer: Bool = true) async {
        capture.stop()
        let task = bufferTask
        bufferTask = nil
        if waitForBuffer { await task?.value }
        await transcriber.stop()
        await audioSession.deactivate()
        isRecording = false
    }

    @MainActor
    private func observeResults() async {
        for await result in transcriber.results {
            if result.isFinal {
                appendFinal(result.text)
                volatileText = ""
            } else {
                volatileText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func appendFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finalText = [finalText, trimmed].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

@available(iOS 26.0, *)
private extension TranscriptionLabView {
    func markAudioReceived() {
        guard !hasReceivedAudio else { return }
        hasReceivedAudio = true
        status = "Receiving audio"
    }
}

/// TCC invokes these callbacks on arbitrary queues, so this bridge must not inherit the view's MainActor.
private func requestHailPermissions() async -> Bool {
    let microphone = await withCheckedContinuation(isolation: nil) { continuation in
        AVAudioApplication.requestRecordPermission { @Sendable granted in
            continuation.resume(returning: granted)
        }
    }
    guard microphone else { return false }

    return await withCheckedContinuation(isolation: nil) { continuation in
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            continuation.resume(returning: status == .authorized)
        }
    }
}
