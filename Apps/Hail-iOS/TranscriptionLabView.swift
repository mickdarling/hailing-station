import AVFAudio
import HailCore
import Speech
import SwiftUI

/// Audio-first capture surface shared by compact and regular-width station layouts.
struct TranscriptionLabView: View {
    let audioSession: any AudioSessionDiagnosticsProviding
    let destinationLabel: String?
    let onCaptureWillBegin: (@MainActor (UUID) -> Void)?
    let onCaptureDidEnd: (@MainActor (UUID, _ resumingPlayback: Bool) -> Void)?
    let onCaptureTeardownCompleted: (@MainActor (UUID) -> Void)?
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
    @State var interruptTask: Task<Void, Never>?
    @State var isForcedTeardown = false
    @State var captureOwnerID = UUID()
    @State var ownsCaptureSuppression = false
    @State var playbackRestoreRequested = false
    @State var startTask: Task<Void, Never>?
    @State var finishTask: Task<Void, Never>?
    @State var finishGeneration: UUID?
    @State var bufferTask: Task<Void, Never>?
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    init(
        audioSession: any AudioSessionDiagnosticsProviding,
        capture: any AudioCapturing = AVAudioEngineCapture(),
        transcriber: (any Transcriber)? = nil,
        destinationLabel: String? = nil,
        onCaptureWillBegin: (@MainActor (UUID) -> Void)? = nil,
        onCaptureDidEnd: (@MainActor (UUID, _ resumingPlayback: Bool) -> Void)? = nil,
        onCaptureTeardownCompleted: (@MainActor (UUID) -> Void)? = nil,
        onFinalized: (@MainActor (String) async throws -> Void)? = nil,
        onEscape: (@MainActor () async throws -> Void)? = nil
    ) {
        self.audioSession = audioSession
        self.destinationLabel = destinationLabel
        self.onCaptureWillBegin = onCaptureWillBegin
        self.onCaptureDidEnd = onCaptureDidEnd
        self.onCaptureTeardownCompleted = onCaptureTeardownCompleted
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
                    startInterrupt(using: onEscape)
                } label: {
                    Label("Escape", systemImage: "xmark.octagon.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isFinalizing || finishTask != nil || interruptTask != nil)
                .accessibilityHint("Discards any active recording and sends Escape immediately to the target.")
            }

            transcriptActions
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .navigationTitle("Conversation")
        .task { await observeResults() }
        .onAppear { restorePlaybackAfterForcedTeardown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restorePlaybackAfterForcedTeardown() }
        }
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
    func beginCaptureExclusivity() {
        isForcedTeardown = false
        playbackRestoreRequested = false
        guard !ownsCaptureSuppression else { return }
        ownsCaptureSuppression = true
        onCaptureWillBegin?(captureOwnerID)
    }

    @MainActor
    func releaseCaptureExclusivityAfterWork() {
        guard !isForcedTeardown else { return }
        endCaptureExclusivity(resumingPlayback: true)
    }

    @MainActor
    func restorePlaybackAfterForcedTeardown() {
        guard scenePhase == .active else { return }
        guard finishTask == nil, startTask == nil, !isStarting, !isFinalizing, !isInterrupting else {
            playbackRestoreRequested = true
            return
        }
        playbackRestoreRequested = false
        isForcedTeardown = false
        if ownsCaptureSuppression {
            endCaptureExclusivity(resumingPlayback: true)
        }
    }

    @MainActor
    func endCaptureExclusivity(resumingPlayback: Bool = true) {
        guard ownsCaptureSuppression else { return }
        ownsCaptureSuppression = false
        onCaptureDidEnd?(captureOwnerID, resumingPlayback)
    }

    @MainActor
    func restorePlaybackIfRequestedAndReady() {
        guard playbackRestoreRequested else { return }
        restorePlaybackAfterForcedTeardown()
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
