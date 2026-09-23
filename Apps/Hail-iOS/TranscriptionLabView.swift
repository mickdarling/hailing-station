import AVFAudio
import HailCore
import Speech
import SwiftUI

/// Audio-first capture surface shared by compact and regular-width station layouts.
struct TranscriptionLabView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let destinationLabel: String?
    let onCaptureWillBegin: (@MainActor () -> Void)?
    let onCaptureDidEnd: (@MainActor (_ resumingPlayback: Bool) -> Void)?
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
    @State var activeUtteranceID: UUID?
    @State var isInterrupting = false
    @State var isForcedTeardown = false
    @State var ownsCaptureSuppression = false
    @State var startTask: Task<Void, Never>?
    @State var bufferTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    init(
        audioSession: any AudioSessionDiagnosticsProviding,
        capture: any AudioCapturing = AVAudioEngineCapture(),
        transcriber: (any Transcriber)? = nil,
        destinationLabel: String? = nil,
        onCaptureWillBegin: (@MainActor () -> Void)? = nil,
        onCaptureDidEnd: (@MainActor (_ resumingPlayback: Bool) -> Void)? = nil,
        onFinalized: (@MainActor (String) async throws -> Void)? = nil,
        onEscape: (@MainActor () async throws -> Void)? = nil
    ) {
        self.audioSession = audioSession
        self.destinationLabel = destinationLabel
        self.onCaptureWillBegin = onCaptureWillBegin
        self.onCaptureDidEnd = onCaptureDidEnd
        self.onFinalized = onFinalized
        self.onEscape = onEscape
        _capture = State(initialValue: capture)
        _transcriber = State(initialValue: transcriber ?? Self.defaultTranscriber())
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label("You", systemImage: "person.wave.2")
                    .font(.headline)
                Spacer()
                if let destinationLabel {
                    Label(destinationLabel, systemImage: "desktopcomputer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            transcriptSurface

            talkButton

            if let onEscape {
                Button(role: .destructive) {
                    Task { await interruptTarget(using: onEscape) }
                } label: {
                    Label("Escape", systemImage: "xmark.octagon.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isFinalizing)
                .accessibilityHint("Discards any active recording and sends Escape immediately to the target.")
            }

            transcriptActions
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .navigationTitle("Conversation")
        .task { await observeResults() }
        .onDisappear {
            startTask?.cancel()
            Task { await finish(force: true) }
        }
    }

    private static func defaultTranscriber() -> any Transcriber {
        if #available(iOS 26.0, *) { return SpeechAnalyzerTranscriber() }
        return SFSpeechRecognizerTranscriber()
    }
}

extension TranscriptionLabView {
    @MainActor
    func prepareCaptureAuthorization() async -> Bool {
        status = "Requesting microphone and speech access…"
        guard await requestHailPermissions() else {
            status = "Microphone and speech recognition permissions are required."
            releaseCaptureExclusivityAfterWork()
            return false
        }
        return true
    }

    @MainActor
    func beginCaptureExclusivity() {
        isForcedTeardown = false
        guard !ownsCaptureSuppression else { return }
        ownsCaptureSuppression = true
        onCaptureWillBegin?()
    }

    @MainActor
    func releaseCaptureExclusivityAfterWork() {
        guard !isForcedTeardown else { return }
        endCaptureExclusivity(resumingPlayback: true)
    }

    @MainActor
    func endCaptureExclusivity(resumingPlayback: Bool = true) {
        guard ownsCaptureSuppression else { return }
        ownsCaptureSuppression = false
        onCaptureDidEnd?(resumingPlayback)
    }

    @MainActor
    func quietReplyAudio() async throws {
        status = "Quieting reply audio…"
        try await Task.sleep(for: .milliseconds(200))
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
